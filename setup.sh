#!/usr/bin/env bash
set -euo pipefail

# --- Configuration ---
# Colors for cleaner output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

# --- Logging ---
log() { echo -e "${GREEN}[$(date +'%H:%M:%S')]${NC} $*"; }
warn() { echo -e "${YELLOW}[WARN]${NC} $*"; }
error() { echo -e "${RED}[ERROR]${NC} $*"; exit 1; }

# --- Script Initialization ---
# Determine if running as root and identify the real user
if [[ $EUID -eq 0 ]]; then
    log "Running as root for system package installation"
    SYSTEM_INSTALL=true
    # Ensure SUDO_USER is set; otherwise, fall back to USER, though less ideal.
    REAL_USER=${SUDO_USER:?"Script must be run with sudo, not as root directly."}
    REAL_HOME=$(getent passwd "$REAL_USER" | cut -d: -f6)
else
    log "Running as user for user-specific installations"
    SYSTEM_INSTALL=false
    REAL_USER=$USER
    REAL_HOME=$HOME
fi

# Define Bun's location and update PATH for the *current script execution*
# This is critical for subsequent commands to find executables installed in this script.
BUN_INSTALL="$REAL_HOME/.bun"
export PATH="$BUN_INSTALL/bin:$PATH"

# --- Functions ---

# Check for required environment variables
check_env() {
    log "Checking for required environment variables..."
    local required=("GITHUB_TOKEN" "FACTORY_API_KEY" "ZAI_API_KEY" "GIT_USER_NAME" "GIT_USER_EMAIL")
    for var in "${required[@]}"; do
        [[ -z "${!var:-}" ]] && error "$var is required. Set it in .env or export before running."
    done

    if [[ -n "${GITHUB_TOKENS:-}" ]]; then
        IFS=',' read -ra TOKENS <<< "$GITHUB_TOKENS"
        log "Found ${#TOKENS[@]} additional GitHub tokens"
    fi
}

# Install or verify system packages (requires root)
install_packages() {
    if [[ "$SYSTEM_INSTALL" != true ]]; then
        log "Skipping system package installation (not running as root)"
        return
    fi

    log "Checking system packages..."
    export DEBIAN_FRONTEND=noninteractive
    apt-get update -qq

    local packages=("curl" "unzip" "htop" "tmux" "nodejs" "git" "jq")
    for package in "${packages[@]}"; do
        if ! dpkg -l | grep -q "^ii  $package "; then
            log "Installing $package..."
            apt-get install -y "$package"
        else
            log "$package already installed"
        fi
    done
}

# Install Bun JS runtime for the correct user
install_bun() {
    local install_logic='
        # This subshell runs as the target user
        log "Checking bun installation for user $REAL_USER..."
        if ! command -v bun &> /dev/null; then
            log "Installing bun..."
            curl -fsSL https://bun.sh/install | bash
            log "Bun installed."

            # Add to shell profile for *future* sessions
            if ! grep -q "BUN_INSTALL" "$REAL_HOME/.bashrc"; then
                echo "" >> "$REAL_HOME/.bashrc"
                echo "# Bun JS Runtime" >> "$REAL_HOME/.bashrc"
                echo "export BUN_INSTALL=\"\$HOME/.bun\"" >> "$REAL_HOME/.bashrc"
                echo "export PATH=\"\$BUN_INSTALL/bin:\$PATH\"" >> "$REAL_HOME/.bashrc"
                log "Added bun to .bashrc"
            fi
        else
            log "Bun is already installed (version: $(bun --version))"
        fi
    '

    log "Executing bun installation logic..."
    sudo -u "$REAL_USER" bash -c "$(declare -f log);
        export HOME=\"$REAL_HOME\"
        export PATH=\"$BUN_INSTALL/bin:\$PATH\"
        REAL_USER=\"$REAL_USER\"
        BUN_INSTALL=\"$BUN_INSTALL\"
        $install_logic
    "
}

# Install Claude Code CLI globally using Bun
install_claude() {
    local install_logic='
        log "Checking claude-code installation..."
        if ! bun pm ls -g | grep -q "@anthropic-ai/claude-code"; then
            log "Installing claude-code..."
            bun install -g @anthropic-ai/claude-code
        else
            log "claude-code is already installed."
        fi
    '

    log "Executing claude-code installation logic..."
    sudo -u "$REAL_USER" bash -c "$(declare -f log);
        export HOME=\"$REAL_HOME\"
        export PATH=\"$BUN_INSTALL/bin:\$PATH\"
        $install_logic
    "
}

# Configure Git with user details from env vars
setup_git() {
    local setup_logic='
        log "Configuring Git for user $GIT_USER_NAME..."
        git config --global user.name "$GIT_USER_NAME"
        git config --global user.email "$GIT_USER_EMAIL"
        git config --global init.defaultBranch main
        git config --global pull.rebase false
        log "Git configured successfully."
    '

    log "Executing Git configuration logic..."
    sudo -u "$REAL_USER" bash -c "$(declare -f log);
        export HOME=\"$REAL_HOME\"
        GIT_USER_NAME=\"$GIT_USER_NAME\"
        GIT_USER_EMAIL=\"$GIT_USER_EMAIL\"
        $setup_logic
    "
}

# Install and configure GitHub CLI
setup_gh() {
    # Define the functions to be added to .bashrc in a non-expanding heredoc.
    # This prevents the parent script from trying to interpret variables like $1.
    local BASHRC_FUNCTIONS
    read -r -d '' BASHRC_FUNCTIONS << 'EOF'

# GitHub account switcher
gh-switch() {
    local account_num=${1:-1}
    if [[ $account_num -eq 1 ]]; then
        if [[ -z "${GITHUB_TOKEN:-}" ]]; then
            echo "Error: GITHUB_TOKEN is not set in your environment." >&2; return 1;
        fi
        echo "$GITHUB_TOKEN" | gh auth login --with-token --hostname github.com
        echo "Switched to primary GitHub account."
    elif [[ -f "$HOME/.config/gh/tokens/token_$account_num" ]]; then
        local token
        token=$(cat "$HOME/.config/gh/tokens/token_$account_num")
        echo "$token" | gh auth login --with-token --hostname github.com
        echo "Switched to GitHub account $account_num."
    else
        echo "Token for account $account_num not found." >&2; return 1;
    fi
}

gh-list() {
    echo "Available GitHub accounts:"
    echo "1: Primary (from GITHUB_TOKEN)"
    for token_file in "$HOME"/.config/gh/tokens/token_*; do
        if [[ -f "$token_file" ]]; then
            local num; num=$(basename "$token_file" | cut -d'_' -f2)
            echo "$num: Additional token"
        fi
    done
}
EOF

    # Install the 'gh' package if needed (requires root)
    if [[ "$SYSTEM_INSTALL" == true ]]; then
        if ! command -v gh &> /dev/null; then
            log "Installing GitHub CLI..."
            (
                export DEBIAN_FRONTEND=noninteractive
                curl -fsSL https://cli.github.com/packages/githubcli-archive-keyring.gpg | dd of=/usr/share/keyrings/githubcli-archive-keyring.gpg
                chmod 644 /usr/share/keyrings/githubcli-archive-keyring.gpg
                echo "deb [arch=$(dpkg --print-architecture) signed-by=/usr/share/keyrings/githubcli-archive-keyring.gpg] https://cli.github.com/packages stable main" > /etc/apt/sources.list.d/github-cli.list
                apt-get update -qq
                apt-get install -y gh
            ) || error "Failed to install GitHub CLI"
        else
            log "GitHub CLI already installed."
        fi
    fi

    # Safely quote the functions to pass them into the subshell
    local QUOTED_BASHRC_FUNCTIONS
    QUOTED_BASHRC_FUNCTIONS=$(printf "%q" "$BASHRC_FUNCTIONS")

    # Configure GH auth and add helpers for the real user
    local configure_logic='
        log "Configuring GitHub CLI for user $REAL_USER..."
        if ! gh auth status &> /dev/null; then
            log "Authenticating with primary GitHub account..."
            echo "$GITHUB_TOKEN" | gh auth login --with-token --hostname github.com
            gh config set git_protocol https
        else
            log "GitHub CLI already authenticated."
        fi

        if [[ -n "${GITHUB_TOKENS:-}" ]]; then
            mkdir -p "$REAL_HOME/.config/gh/tokens"
            IFS="," read -ra TOKENS <<< "$GITHUB_TOKENS"
            for i in "${!TOKENS[@]}"; do
                local token="${TOKENS[$i]}"
                local token_file="$REAL_HOME/.config/gh/tokens/token_$((i+2))"
                if [[ ! -f "$token_file" ]]; then
                    echo "$token" > "$token_file"
                    chmod 600 "$token_file"
                    log "Stored additional GitHub token $((i+2))"
                fi
            done

            if ! grep -q "# GitHub account switcher" "$REAL_HOME/.bashrc"; then
                echo "" >> "$REAL_HOME/.bashrc"
                echo $QUOTED_BASHRC_FUNCTIONS >> "$REAL_HOME/.bashrc"
                log "Added GitHub account switcher functions to ~/.bashrc"
            fi
        fi
    '

    sudo -u "$REAL_USER" bash -c "$(declare -f log);
        export HOME=\"$REAL_HOME\"
        export GITHUB_TOKEN=\"$GITHUB_TOKEN\"
        export GITHUB_TOKENS=\"$GITHUB_TOKENS\"
        REAL_USER=\"$REAL_USER\"
        QUOTED_BASHRC_FUNCTIONS=$QUOTED_BASHRC_FUNCTIONS
        $configure_logic
    "
}


# Install and configure Factory CLI
install_factory() {
    export PATH="$REAL_HOME/.local/bin:$PATH"
    
    local install_logic='
        log "Checking Factory CLI..."
        if ! command -v factory &> /dev/null; then
            log "Installing Factory CLI..."
            curl -fsSL https://app.factory.ai/cli | sh
            if ! grep -q ".local/bin" "$REAL_HOME/.bashrc"; then
                echo "" >> "$REAL_HOME/.bashrc"
                echo "# Factory CLI Path" >> "$REAL_HOME/.bashrc"
                echo "export PATH=\"\$HOME/.local/bin:\$PATH\"" >> "$REAL_HOME/.bashrc"
            fi
        else
            log "Factory CLI already installed."
        fi
    '
    
    sudo -u "$REAL_USER" bash -c "$(declare -f log);
        export HOME=\"$REAL_HOME\"
        export PATH=\"$REAL_HOME/.local/bin:\$PATH\"
        $install_logic
    "
}

configure_factory() {
    local configure_logic='
        log "Configuring Factory..."
        local config_dir="$REAL_HOME/.factory"
        local config_file="$config_dir/config.json"
        mkdir -p "$config_dir"

        if [[ ! -f "$config_file" ]]; then
            log "Creating new Factory config file..."
            cat > "$config_file" << EOF
{
  "api_key": "$FACTORY_API_KEY",
  "custom_models": [
    {
      "model_display_name": "GLM 4.6 Coding Plan",
      "model": "glm-4.6",
      "base_url": "https://api.z.ai/api/anthropic",
      "api_key": "$ZAI_API_KEY",
      "provider": "zai"
    }
  ]
}
EOF
        else
            log "Factory config file already exists. Verifying settings..."
            # Simple verification for now. Can be expanded to update keys.
            if ! jq -e ".api_key == \"$FACTORY_API_KEY\"" "$config_file" >/dev/null; then
                 warn "Factory API key in config does not match .env. Manual check recommended."
            fi
        fi
    '
    
    sudo -u "$REAL_USER" bash -c "$(declare -f log warn);
        export HOME=\"$REAL_HOME\"
        export FACTORY_API_KEY=\"$FACTORY_API_KEY\"
        export ZAI_API_KEY=\"$ZAI_API_KEY\"
        REAL_HOME=\"$REAL_HOME\"
        $configure_logic
    "
}

# Create a standard workspace directory
setup_workspace() {
    local setup_logic='
        log "Setting up workspace directory..."
        if [[ ! -d "$REAL_HOME/code" ]]; then
            mkdir -p "$REAL_HOME/code"
            log "Created ~/code directory."
        else
            log "~/code directory already exists."
        fi
    '
    
    sudo -u "$REAL_USER" bash -c "$(declare -f log);
        REAL_HOME=\"$REAL_HOME\"
        $setup_logic
    "
}

# --- Main Execution ---
main() {
    log "Starting dev environment setup..."
    check_env
    install_packages
    setup_git
    install_bun
    install_claude
    setup_gh
    install_factory
    configure_factory
    setup_workspace

    log "${GREEN}Setup complete!${NC}"
    log "Run 'source ~/.bashrc' or start a new shell to apply changes."
    log "Workspace ready at: $REAL_HOME/code"
    log "Use 'gh-switch <num>' and 'gh-list' to manage GitHub accounts."
}

# Run the main function with all script arguments
main "$@"
