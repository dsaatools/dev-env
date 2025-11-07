#!/usr/bin/env bash
# Fail on any error, unbound variable, or pipe failure
set -euo pipefail

# --- Configuration ---
# Colors for cleaner output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
NC='\033[0m'

# --- Logging and Error Handling ---
log() { echo -e "${CYAN}[$(date +'%H:%M:%S')]${NC} $*"; }
warn() { echo -e "${YELLOW}[WARN]${NC} $*"; }
error() { echo -e "${RED}[ERROR]${NC} $*" >&2; exit 1; }

# Trap to catch errors and exit gracefully
SCRIPT_COMPLETED=false
trap '[[ "$SCRIPT_COMPLETED" == false ]] && error "Script exited prematurely on line $LINENO."' ERR

# --- Script Initialization ---
log "Initializing script..."
# Ensure script is run with sudo for package management
if [[ $EUID -ne 0 ]] || [[ -z "${SUDO_USER:-}" ]]; then
    error "This script must be run with sudo (e.g., 'sudo bash -c \"...\"')."
fi

REAL_USER=$SUDO_USER
REAL_HOME=$(getent passwd "$REAL_USER" | cut -d: -f6)
log "Running as root on behalf of user: ${GREEN}$REAL_USER${NC} (home: $REAL_HOME)"

# Define key paths and export them for the script's context
export BUN_INSTALL="$REAL_HOME/.bun"
export FACTORY_INSTALL="$REAL_HOME/.local"
export PATH="$BUN_INSTALL/bin:$FACTORY_INSTALL/bin:$PATH"

# --- Functions ---

check_env() {
    log "--- Starting: Environment Check ---"
    local required=("GITHUB_TOKEN" "FACTORY_API_KEY" "ZAI_API_KEY" "GIT_USER_NAME" "GIT_USER_EMAIL")
    for var in "${required[@]}"; do
        [[ -z "${!var:-}" ]] && error "$var is required. Set it in .env or export before running."
    done
    log "All required environment variables are present."
    log "--- Finished: Environment Check ---"
}

install_packages() {
    log "--- Starting: System Package Installation ---"
    export DEBIAN_FRONTEND=noninteractive
    log "Updating package lists..."
    apt-get update -qq

    local packages=("curl" "unzip" "htop" "tmux" "nodejs" "git" "jq")
    for pkg in "${packages[@]}"; do
        if ! dpkg -l | grep -q "^ii  $pkg "; then
            log "Installing $pkg..."
            apt-get install -y "$pkg"
        else
            log "$pkg is already installed."
        fi
    done
    log "--- Finished: System Package Installation ---"
}

setup_git() {
    log "--- Starting: Git Configuration ---"
    sudo -u "$REAL_USER" bash -c "
        set -euo pipefail
        git config --global user.name '$GIT_USER_NAME'
        git config --global user.email '$GIT_USER_EMAIL'
        git config --global init.defaultBranch main
    " || error "Failed to configure Git."
    log "Git configured globally for user '$GIT_USER_NAME'."
    log "--- Finished: Git Configuration ---"
}

install_bun() {
    log "--- Starting: Bun Installation ---"
    local bun_logic='
        set -euo pipefail
        if ! command -v bun &>/dev/null; then
            echo "Installing Bun JS runtime..."
            curl -fsSL https://bun.sh/install | bash
            
            # Add to shell profile for future sessions
            if ! grep -q "BUN_INSTALL" "$HOME/.bashrc"; then
                echo "" >> "$HOME/.bashrc"
                echo "# Bun JS Runtime" >> "$HOME/.bashrc"
                echo "export BUN_INSTALL=\"\$HOME/.bun\"" >> "$HOME/.bashrc"
                echo "export PATH=\"\$BUN_INSTALL/bin:\$PATH\"" >> "$HOME/.bashrc"
                echo "Bun environment variables added to ~/.bashrc"
            fi
        else
            echo "Bun is already installed (version: $(bun --version))."
        fi
    '
    sudo -u "$REAL_USER" HOME="$REAL_HOME" bash -c "$bun_logic" || error "Bun installation failed."
    log "--- Finished: Bun Installation ---"
}

install_claude() {
    log "--- Starting: Claude Code CLI Installation ---"
    local claude_logic='
        set -euo pipefail
        export PATH="$HOME/.bun/bin:$PATH"
        if ! bun pm ls -g | grep -q "@anthropic-ai/claude-code"; then
            echo "Installing @anthropic-ai/claude-code globally..."
            bun install -g @anthropic-ai/claude-code
        else
            echo "Claude Code CLI is already installed."
        fi
    '
    sudo -u "$REAL_USER" HOME="$REAL_HOME" bash -c "$claude_logic" || error "Claude Code CLI installation failed."
    log "--- Finished: Claude Code CLI Installation ---"
}

setup_gh() {
    log "--- Starting: GitHub CLI Setup ---"
    # 1. Install package if needed
    if ! command -v gh &>/dev/null; then
        log "Installing GitHub CLI package..."
        (
            curl -fsSL https://cli.github.com/packages/githubcli-archive-keyring.gpg | dd of=/usr/share/keyrings/githubcli-archive-keyring.gpg
            chmod 644 /usr/share/keyrings/githubcli-archive-keyring.gpg
            echo "deb [arch=$(dpkg --print-architecture) signed-by=/usr/share/keyrings/githubcli-archive-keyring.gpg] https://cli.github.com/packages stable main" > /etc/apt/sources.list.d/github-cli.list
            apt-get update -qq
            apt-get install -y gh
        ) || error "Failed to install GitHub CLI package."
    else
        log "GitHub CLI is already installed."
    fi

    # 2. Authenticate and configure for the user
    local gh_logic='
        set -euo pipefail
        echo "Authenticating GitHub CLI..."
        # Use primary token for login
        echo "$GITHUB_TOKEN" | gh auth login --with-token --hostname github.com
        gh config set git_protocol https
        echo "GitHub CLI authenticated successfully."

        # Store additional tokens if they exist
        if [[ -n "$GITHUB_TOKENS" ]]; then
            mkdir -p "$HOME/.config/gh/tokens"
            IFS="," read -ra TOKENS <<< "$GITHUB_TOKENS"
            for i in "${!TOKENS[@]}"; do
                local token_file="$HOME/.config/gh/tokens/token_$((i+2))"
                echo "${TOKENS[$i]}" > "$token_file"
                chmod 600 "$token_file"
                echo "Stored additional GitHub token $((i+2))."
            done
        fi
    '
    sudo -u "$REAL_USER" HOME="$REAL_HOME" GITHUB_TOKEN="$GITHUB_TOKEN" GITHUB_TOKENS="${GITHUB_TOKENS:-}" bash -c "$gh_logic" || error "GitHub CLI authentication failed."
    log "--- Finished: GitHub CLI Setup ---"
}

install_factory() {
    log "--- Starting: Factory CLI Installation ---"
    local factory_logic='
        set -euo pipefail
        if ! command -v factory &>/dev/null; then
            echo "Installing Factory CLI..."
            curl -fsSL https://app.factory.ai/cli | sh
            
            if ! grep -q ".local/bin" "$HOME/.bashrc"; then
                echo "" >> "$HOME/.bashrc"
                echo "# Factory CLI Path" >> "$HOME/.bashrc"
                echo "export PATH=\"\$HOME/.local/bin:\$PATH\"" >> "$HOME/.bashrc"
                echo "Factory CLI path added to ~/.bashrc"
            fi
        else
            echo "Factory CLI is already installed."
        fi
    '
    sudo -u "$REAL_USER" HOME="$REAL_HOME" bash -c "$factory_logic" || error "Factory CLI installation failed."
    log "--- Finished: Factory CLI Installation ---"
}

configure_factory() {
    log "--- Starting: Factory CLI Configuration ---"
    local factory_config_logic='
        set -euo pipefail
        local config_dir="$HOME/.factory"
        local config_file="$config_dir/config.json"
        mkdir -p "$config_dir"
        
        echo "Writing Factory config to $config_file..."
        # Use jq to safely build the JSON config
        jq -n \
          --arg factory_key "$FACTORY_API_KEY" \
          --arg zai_key "$ZAI_API_KEY" \
          '{
            "api_key": $factory_key,
            "custom_models": [
              {
                "model_display_name": "GLM 4.6 Coding Plan",
                "model": "glm-4.6",
                "base_url": "https://api.z.ai/api/anthropic",
                "api_key": $zai_key,
                "provider": "zai"
              }
            ]
          }' > "$config_file"
        echo "Factory config file created/updated."
    '
    sudo -u "$REAL_USER" HOME="$REAL_HOME" FACTORY_API_KEY="$FACTORY_API_KEY" ZAI_API_KEY="$ZAI_API_KEY" bash -c "$factory_config_logic" || error "Factory CLI configuration failed."
    log "--- Finished: Factory CLI Configuration ---"
}

setup_workspace() {
    log "--- Starting: Workspace Setup ---"
    local workspace_logic='
        set -euo pipefail
        local code_dir="$HOME/code"
        if [[ ! -d "$code_dir" ]]; then
            mkdir -p "$code_dir"
            echo "Created workspace directory at ~/code."
        else
            echo "Workspace directory ~/code already exists."
        fi
    '
    sudo -u "$REAL_USER" HOME="$REAL_HOME" bash -c "$workspace_logic" || error "Workspace setup failed."
    log "--- Finished: Workspace Setup ---"
}

# --- Main Execution ---
main() {
    log "${GREEN}Starting Full Dev Environment Setup for user $REAL_USER...${NC}"
    
    check_env
    install_packages
    setup_git
    install_bun
    install_claude
    setup_gh
    install_factory
    configure_factory
    setup_workspace

    # Set completion flag to prevent error trap on successful exit
    SCRIPT_COMPLETED=true
    
    log "${GREEN}===============================================${NC}"
    log "${GREEN}          SETUP COMPLETE! 🎉          ${NC}"
    log "${GREEN}===============================================${NC}"
    log "To apply all changes, please start a new shell or run:"
    log "${YELLOW}source $REAL_HOME/.bashrc${NC}"
}

# Run the main function
main
