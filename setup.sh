#!/usr/bin/env bash
# Fail on any error, unbound variable, or pipe failure. Stop on first error.
set -euo pipefail

# --- Configuration ---
# Pretty colors for the logs
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
NC='\033[0m'

# --- Logging and Error Handling ---
log() { echo -e "${CYAN}[$(date +'%H:%M:%S')]${NC} $*"; }
warn() { echo -e "${YELLOW}[WARN]${NC} $*"; }
# Error messages go to stderr and exit
error() { echo -e "${RED}[ERROR]${NC} $*" >&2; exit 1; }

# Trap to catch unexpected exits
trap 'error "Script exited prematurely on line $LINENO."' ERR

# --- Script Initialization ---
log "Initializing script..."
# Script must run as root to install packages
if [[ $EUID -ne 0 ]] || [[ -z "${SUDO_USER:-}" ]]; then
    error "This script needs to be run with sudo."
fi

REAL_USER=$SUDO_USER
# Reliably get the user's home directory
REAL_HOME=$(getent passwd "$REAL_USER" | cut -d: -f6)
log "Running as root for user: ${GREEN}$REAL_USER${NC} (home: $REAL_HOME)"

# Define key paths and export them for subshells
export BUN_INSTALL="$REAL_HOME/.bun"
export FACTORY_INSTALL="$REAL_HOME/.local"
export PATH="$BUN_INSTALL/bin:$FACTORY_INSTALL/bin:$PATH"

# --- Functions ---

check_env() {
    log "--- Checking Environment Variables ---"
    # Check for all required vars at once
    local required=("GITHUB_TOKEN" "FACTORY_API_KEY" "ZAI_API_KEY" "GIT_USER_NAME" "GIT_USER_EMAIL")
    local missing=()
    for var in "${required[@]}"; do
        [[ -z "${!var:-}" ]] && missing+=("$var")
    done

    if [[ ${#missing[@]} -gt 0 ]]; then
        error "Required environment variables are not set: ${missing[*]}"
    fi
    log "All required environment variables are set."
}

install_packages() {
    log "--- Installing System Packages ---"
    export DEBIAN_FRONTEND=noninteractive
    log "Updating package lists..."
    apt-get update -qq

    # Install all packages in one go. apt is idempotent.
    local packages=(
        curl
        unzip
        htop
        tmux
        nodejs
        git
        jq
        gh # Install gh from apt directly
    )
    log "Installing: ${packages[*]}..."
    apt-get install -y --no-install-recommends "${packages[@]}"
    log "System packages are up to date."
}

setup_git() {
    log "--- Configuring Git ---"
    # Run git config as the actual user
    sudo -u "$REAL_USER" git config --global user.name "$GIT_USER_NAME"
    sudo -u "$REAL_USER" git config --global user.email "$GIT_USER_EMAIL"
    sudo -u "$REAL_USER" git config --global init.defaultBranch main
    log "Git configured for user '$GIT_USER_NAME'."
}

install_bun() {
    log "--- Installing Bun JS Runtime ---"
    if sudo -u "$REAL_USER" bash -c 'command -v bun &>/dev/null'; then
        log "Bun is already installed."
        return
    fi

    log "Downloading and installing Bun..."
    # The official installer is safe to run as the user
    sudo -u "$REAL_USER" bash -c "curl -fsSL https://bun.sh/install | bash"

    log "Adding Bun to .bashrc..."
    sudo -u "$REAL_USER" bash -c '
        {
            echo ""
            echo "# Bun JS Runtime"
            echo "export BUN_INSTALL=\"\$HOME/.bun\""
            echo "export PATH=\"\$BUN_INSTALL/bin:\$PATH\""
        } >> "$HOME/.bashrc"
    '
    log "Bun installation complete."
}

install_claude_cli() {
    log "--- Installing Claude Code CLI ---"
    # Logic to run as the user, ensuring bun is on the PATH
    local claude_logic='
        set -euo pipefail
        export PATH="$HOME/.bun/bin:$PATH"
        if bun pm ls -g | grep -q "@anthropic-ai/claude-code"; then
            echo "Claude Code CLI is already installed."
        else
            echo "Installing @anthropic-ai/claude-code globally with bun..."
            bun install -g @anthropic-ai/claude-code
        fi
    '
    sudo -u "$REAL_USER" HOME="$REAL_HOME" bash -c "$claude_logic"
}

setup_gh() {
    log "--- Authenticating GitHub CLI ---"
    # The gh package is installed in install_packages now.
    # The key is to pass the token via stdin, not as an env var gh can see.
    # We pass the token as a positional parameter ($1) to the subshell.
    local gh_auth_logic='
        set -euo pipefail
        # $1 is the GITHUB_TOKEN passed from the main script
        # This avoids the env var conflict that your original script hit.
        echo "Authenticating gh with token..."
        echo "$1" | gh auth login --with-token --hostname github.com

        gh config set git_protocol https
        echo "GitHub CLI authenticated successfully."
    '
    # Execute the logic, passing the token as an argument.
    sudo -u "$REAL_USER" HOME="$REAL_HOME" bash -c "$gh_auth_logic" -- "$GITHUB_TOKEN"
}

install_factory_cli() {
    log "--- Installing Factory CLI ---"
    if sudo -u "$REAL_USER" bash -c 'command -v factory &>/dev/null'; then
        log "Factory CLI is already installed."
        return
    fi
    
    log "Downloading and installing Factory CLI..."
    sudo -u "$REAL_USER" bash -c "curl -fsSL https://app.factory.ai/cli | sh"

    log "Adding Factory to .bashrc..."
    sudo -u "$REAL_USER" bash -c '
        {
            echo ""
            echo "# Factory AI CLI"
            echo "export PATH=\"\$HOME/.local/bin:\$PATH\""
        } >> "$HOME/.bashrc"
    '
}

configure_factory() {
    log "--- Configuring Factory CLI ---"
    # Use a scriptlet to create the config as the user. JQ is much safer than echo.
    local factory_config_logic='
        set -euo pipefail
        # Use positional params for keys to avoid quoting issues
        local factory_key="$1"
        local zai_key="$2"
        
        local config_dir="$HOME/.factory"
        local config_file="$config_dir/config.json"
        mkdir -p "$config_dir"
        
        echo "Writing Factory config to $config_file..."
        jq -n \
          --arg factory_key "$factory_key" \
          --arg zai_key "$zai_key" \
          '"'"'{
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
          }'"'"' > "$config_file"
        echo "Factory config created."
    '
    # Execute as user, passing keys as secure arguments
    sudo -u "$REAL_USER" HOME="$REAL_HOME" bash -c "$factory_config_logic" -- "$FACTORY_API_KEY" "$ZAI_API_KEY"
}

setup_workspace() {
    log "--- Setting up Workspace ---"
    sudo -u "$REAL_USER" mkdir -p "$REAL_HOME/code"
    log "Workspace directory '~/code' is ready."
}

# --- Main Execution ---
main() {
    log "${GREEN}Starting Dev Environment Setup for $REAL_USER...${NC}"
    
    check_env
    install_packages
    setup_git
    install_bun
    install_claude_cli
    setup_gh
    install_factory_cli
    configure_factory
    setup_workspace

    # Unset the trap on successful completion
    trap - ERR
    
    log "${GREEN}===============================================${NC}"
    log "${GREEN}          SETUP COMPLETE! 🎉          ${NC}"
    log "${GREEN}===============================================${NC}"
    log "To apply changes, start a new shell or run:"
    log "${YELLOW}source $REAL_HOME/.bashrc${NC}"
}

# Engage!
main
