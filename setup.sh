#!/usr/bin/env bash
set -euo pipefail

# --- Configuration ---
# Colors for cleaner output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'
SCRIPT_COMPLETED=false

# --- Error Handling & Logging ---
log() { echo -e "${GREEN}[$(date +'%H:%M:%S')]${NC} $*"; }
warn() { echo -e "${YELLOW}[WARN]${NC} $*"; }
error() { echo -e "${RED}[ERROR]${NC} $*" >&2; exit 1; }

# Trap to catch errors and exit signals
err_handler() {
    local exit_code=$?
    error "Script exited unexpectedly on line ${BASH_LINENO[0]} with status ${exit_code}."
}
trap err_handler ERR

# Trap to check for successful completion on script exit
cleanup() {
    if [[ "$SCRIPT_COMPLETED" != true ]]; then
        warn "Script did not run to completion. Review the log for errors."
    fi
}
trap cleanup EXIT


# --- Script Initialization ---
# Determine if running as root and identify the real user
if [[ $EUID -eq 0 ]]; then
    log "Running as root for system package installation."
    SYSTEM_INSTALL=true
    # Ensure SUDO_USER is set; otherwise, the script can't operate on the user's home dir.
    REAL_USER=${SUDO_USER:?"This script must be run with sudo, not directly as root."}
    REAL_HOME=$(getent passwd "$REAL_USER" | cut -d: -f6)
else
    log "Running as non-root user. System package installation will be skipped."
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
        [[ -z "${!var:-}" ]] && error "$var is required. Set it in .env or export it."
    done

    if [[ -n "${GITHUB_TOKENS:-}" ]]; then
        IFS=',' read -ra TOKENS <<< "$GITHUB_TOKENS"
        log "Found ${#TOKENS[@]} additional GitHub tokens."
    fi
}

# Install or verify system packages (requires root)
install_packages() {
    if [[ "$SYSTEM_INSTALL" != true ]]; then
        log "Skipping system package installation (not running as root)."
        return
    fi

    log "Checking system packages..."
    export DEBIAN_FRONTEND=noninteractive
    apt-get update -qq

    local packages=("curl" "unzip" "htop" "tmux" "nodejs" "git" "jq")
    for package in "${packages[@]}"; do
        if ! dpkg -l | grep -q "^ii  $package "; then
            log "Installing $package..."
            apt-get install -y -qq "$package"
        else
            log "$package is already installed."
        fi
    done
}

# Install Bun JS runtime for the correct user
install_bun() {
    log "Preparing to check Bun installation..."
    sudo -u "$REAL_USER" bash -c '
        set -euo pipefail
        # Inherit log functions and env vars
        declare -f log
        export HOME="'"$REAL_HOME"'"
        export BUN_INSTALL="'"$BUN_INSTALL"'"
        export PATH="$BUN_INSTALL/bin:$PATH"

        log "Checking Bun installation for user '"$REAL_USER"'..."
        if ! command -v bun &> /dev/null; then
            log "Installing Bun..."
            curl -fsSL https://bun.sh/install | bash
            
            # Add to shell profile for future sessions
            if ! grep -q "BUN_INSTALL" "'"$REAL_HOME"'/.bashrc"; then
                {
                    echo ""
                    echo "# Bun JS Runtime"
                    echo "export BUN_INSTALL=\"\$HOME/.bun\""
                    echo "export PATH=\"\$BUN_INSTALL/bin:\$PATH\""
                } >> "'"$REAL_HOME"'/.bashrc"
                log "Added bun to .bashrc."
            fi
        else
            log "Bun is already installed (version: $(bun --version))."
        fi
    '
}

# Install Claude Code CLI globally using Bun
install_claude() {
    log "Preparing to check claude-code installation..."
    sudo -u "$REAL_USER" bash -c '
        set -euo pipefail
        declare -f log
        export HOME="'"$REAL_HOME"'"
        export BUN_INSTALL="'"$BUN_INSTALL"'"
        export PATH="$BUN_INSTALL/bin:$PATH"

        log "Checking claude-code installation..."
        if ! bun pm ls -g | grep -q "@anthropic-ai/claude-code"; then
            log "Installing claude-code..."
            bun install -g @anthropic-ai/claude-code
        else
            log "claude-code is already installed."
        fi
    '
}

# Configure Git with user details from env vars
setup_git() {
    log "Preparing to configure Git..."
    sudo -u "$REAL_USER" bash -c '
        set -euo pipefail
        declare -f log
        export HOME="'"$REAL_HOME"'"

        log "Configuring Git for user '"$GIT_USER_NAME"'..."
        git config --global user.name "'"$GIT_USER_NAME"'"
        git config --global user.email "'"$GIT_USER_EMAIL"'"
        git config --global init.defaultBranch main
        git config --global pull.rebase false
        log "Git configured successfully."
    '
}

# Install and configure GitHub CLI
setup_gh() {
    log "Starting GitHub CLI setup..."
    # Install the 'gh' package if needed (requires root)
    if [[ "$SYSTEM_INSTALL" == true ]]; then
        if ! command -v gh &> /dev/null; then
            log "Installing GitHub CLI package..."
            (
                type -p curl >/dev/null || (apt-get update && apt-get install -y curl)
                curl -fsSL https://cli.github.com/packages/githubcli-archive-keyring.gpg | dd of=/usr/share/keyrings/githubcli-archive-keyring.gpg &&
                chmod go+r /usr/share/keyrings/githubcli-archive-keyring.gpg &&
                echo "deb [arch=$(dpkg --print-architecture) signed-by=/usr/share/keyrings/githubcli-archive-keyring.gpg] https://cli.github.com/packages stable main" > /etc/apt/sources.list.d/github-cli.list &&
                apt-get update &&
                apt-get install -y gh
            ) || error "Failed to install GitHub CLI"
        else
            log "GitHub CLI package is already installed."
        fi
    fi

    # Define helper functions in a non-expanding heredoc to protect variables like $1
    local BASHRC_FUNCTIONS
    read -r -d '' BASHRC_FUNCTIONS << 'EOF'

# GitHub account switcher
gh-switch() {
    local account_num=${1:-1}
    if [[ $account_num -eq 1 ]]; then
        [[ -z "${GITHUB_TOKEN:-}" ]] && { echo "Error: GITHUB_TOKEN is not set." >&2; return 1; }
        echo "$GITHUB_TOKEN" | gh auth login --with-token --hostname github.com
        echo "Switched to primary GitHub account."
    elif [[ -f "$HOME/.config/gh/tokens/token_$account_num" ]]; then
        gh auth login --with-token --hostname github.com < "$HOME/.config/gh/tokens/token_$account_num"
        echo "Switched to GitHub account $account_num."
    else
        echo "Token for account $account_num not found." >&2; return 1;
    fi
}

gh-list() {
    echo "Available GitHub accounts:"
    echo "1: Primary (from GITHUB_TOKEN env var)"
    for token_file in "$HOME"/.config/gh/tokens/token_*; do
        [[ -f "$token_file" ]] && echo "$(basename "$token_file" | cut -d'_' -f2): Additional token"
    done
}
EOF

    # Configure GH auth and add helpers for the real user
    log "Preparing to configure GitHub CLI for user..."
    sudo -u "$REAL_USER" bash -c '
        set -euo pipefail
        declare -f log
        export HOME="'"$REAL_HOME"'"
        export GITHUB_TOKEN="'"$GITHUB_TOKEN"'"
        export GITHUB_TOKENS="'"$GITHUB_TOKENS"'"

        log "Configuring GitHub CLI authentication for '"$REAL_USER"'..."
        echo "$GITHUB_TOKEN" | gh auth login --with-token --hostname github.com
        gh config set git_protocol https

        if [[ -n "$GITHUB_TOKENS" ]]; then
            log "Storing additional GitHub tokens..."
            mkdir -p "$HOME/.config/gh/tokens"
            IFS="," read -ra TOKENS <<< "$GITHUB_TOKENS"
            for i in "${!TOKENS[@]}"; do
                local token_file="$HOME/.config/gh/tokens/token_$((i+2))"
                echo "${TOKENS[$i]}" > "$token_file"
                chmod 600 "$token_file"
            done
        fi

        if ! grep -q "# GitHub account switcher" "$HOME/.bashrc"; then
            echo "Adding GitHub account switcher functions to ~/.bashrc..."
            # Safely append the functions to .bashrc
            printf "\n%s\n" '"${BASHRC_FUNCTIONS//\'/\\\'}"' >> "$HOME/.bashrc"
        fi
    ' -- "unused" "$BASHRC_FUNCTIONS" # Pass functions as an argument
}

# Install and configure Factory CLI
install_factory() {
    log "Preparing to check Factory CLI..."
    sudo -u "$REAL_USER" bash -c '
        set -euo pipefail
        declare -f log
        export HOME="'"$REAL_HOME"'"
        export PATH="$HOME/.local/bin:$PATH"

        log "Checking Factory CLI..."
        if ! command -v factory &> /dev/null; then
            log "Installing Factory CLI..."
            curl -fsSL https://app.factory.ai/cli | sh
            if ! grep -q ".local/bin" "$HOME/.bashrc"; then
                {
                    echo ""
                    echo "# Factory CLI Path"
                    echo "export PATH=\"\$HOME/.local/bin:\$PATH\""
                } >> "$HOME/.bashrc"
            fi
        else
            log "Factory CLI already installed."
        fi
    '
}

configure_factory() {
    log "Preparing to configure Factory..."
    sudo -u "$REAL_USER" bash -c '
        set -euo pipefail
        declare -f log warn
        export HOME="'"$REAL_HOME"'"
        export FACTORY_API_KEY="'"$FACTORY_API_KEY"'"
        export ZAI_API_KEY="'"$ZAI_API_KEY"'"

        local config_dir="$HOME/.factory"
        local config_file="$config_dir/config.json"
        log "Checking Factory config at $config_file..."
        mkdir -p "$config_dir"

        # Overwrite config to ensure it is always up-to-date with .env
        log "Writing Factory config file..."
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
        log "Factory config written successfully."
    '
}

# Create a standard workspace directory
setup_workspace() {
    log "Preparing to set up workspace..."
    sudo -u "$REAL_USER" mkdir -p "$REAL_HOME/code"
    log "Workspace directory ensured at $REAL_HOME/code."
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
    log "Run 'source ~/.bashrc' or start a new terminal to apply all changes."
    log "Your workspace is ready at: $REAL_HOME/code"
    log "Use 'gh-switch <num>' and 'gh-list' to manage GitHub accounts."

    # This flag tells our EXIT trap that we finished successfully.
    SCRIPT_COMPLETED=true
}

# Run the main function
main
