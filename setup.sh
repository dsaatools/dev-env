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
# Require sudo and get the real user
if [[ $EUID -ne 0 ]] || [[ -z "${SUDO_USER:-}" ]]; then
    error "This script must be run with sudo, e.g., 'sudo bash -c ...'"
fi
REAL_USER=$SUDO_USER
REAL_HOME=$(getent passwd "$REAL_USER" | cut -d: -f6)
log "Running as root on behalf of user: ${GREEN}$REAL_USER${NC} (home: $REAL_HOME)"

# Helper function to run commands as the real user
as_user() {
    sudo -u "$REAL_USER" HOME="$REAL_HOME" bash -c "$@"
}

# --- Functions ---

check_env() {
    log "--- Starting: Environment Check ---"
    local required=("GITHUB_TOKEN" "FACTORY_API_KEY" "ZAI_API_KEY" "GIT_USER_NAME" "GIT_USER_EMAIL")
    local missing=()
    for var in "${required[@]}"; do
        if [[ -z "${!var:-}" ]]; then
            missing+=("$var")
        fi
    done
    if [[ ${#missing[@]} -gt 0 ]]; then
        error "Missing required environment variables: ${missing[*]}. Set them in .env before running."
    fi
    log "All required environment variables are present."
    log "--- Finished: Environment Check ---"
}

install_packages() {
    log "--- Starting: System Package Installation ---"
    export DEBIAN_FRONTEND=noninteractive
    log "Updating package lists..."
    apt-get update -qq
    local packages=("curl" "unzip" "htop" "tmux" "nodejs" "git" "jq" "gh")
    log "Installing required packages: ${packages[*]}..."
    apt-get install -y "${packages[@]}"
    log "--- Finished: System Package Installation ---"
}

setup_git() {
    log "--- Starting: Git Configuration ---"
    as_user "
        git config --global user.name '$GIT_USER_NAME'
        git config --global user.email '$GIT_USER_EMAIL'
        git config --global init.defaultBranch main
    "
    log "Git configured globally for user '$GIT_USER_NAME'."
    log "--- Finished: Git Configuration ---"
}

install_bun() {
    log "--- Starting: Bun Installation ---"
    as_user '
        set -e
        export BUN_INSTALL="$HOME/.bun"
        export PATH="$BUN_INSTALL/bin:$PATH"
        if ! command -v bun &>/dev/null; then
            echo "Installing Bun JS runtime..."
            curl -fsSL https://bun.sh/install | bash
        else
            echo "Bun is already installed (version: $(bun --version)). Updating..."
            bun upgrade
        fi
        if ! grep -q "BUN_INSTALL" "$HOME/.bashrc" 2>/dev/null; then
            echo -e "\n# Bun JS Runtime\nexport BUN_INSTALL=\"\$HOME/.bun\"\nexport PATH=\"\$BUN_INSTALL/bin:\$PATH\"" >> "$HOME/.bashrc"
            echo "Bun environment variables added to ~/.bashrc"
        fi
    '
    log "--- Finished: Bun Installation ---"
}

install_claude() {
    log "--- Starting: Claude Code CLI Installation ---"
    as_user '
        set -e
        export BUN_INSTALL="$HOME/.bun"
        export PATH="$BUN_INSTALL/bin:$PATH"
        if ! command -v bun &>/dev/null; then error "Bun not found, cannot install Claude Code CLI"; fi
        if ! bun pm ls -g 2>/dev/null | grep -q "@anthropic-ai/claude-code"; then
            echo "Installing @anthropic-ai/claude-code globally..."
            bun install -g @anthropic-ai/claude-code
        else
            echo "Claude Code CLI is already installed."
        fi
    '
    log "--- Finished: Claude Code CLI Installation ---"
}

setup_gh() {
    log "--- Starting: GitHub CLI Setup ---"
    as_user '
        set -e
        echo "Authenticating GitHub CLI..."
        echo "'"$GITHUB_TOKEN"'" | gh auth login --with-token --hostname github.com
        gh config set git_protocol https
        echo "GitHub CLI authenticated and configured successfully."
    '
    log "--- Finished: GitHub CLI Setup ---"
}

install_factory() {
    log "--- Starting: Factory CLI (droid) Installation ---"
    as_user '
        set -e
        if ! command -v droid &>/dev/null; then
            echo "Installing Factory CLI (droid)..."
            curl -fsSL https://app.factory.ai/cli | sh
            if ! grep -q ".local/bin" "$HOME/.bashrc" 2>/dev/null; then
                echo -e "\n# Factory CLI (droid) Path\nexport PATH=\"\$HOME/.local/bin:\$PATH\"" >> "$HOME/.bashrc"
                echo "Factory CLI path added to ~/.bashrc"
            fi
        else
            echo "Factory CLI (droid) is already installed."
        fi
    '
    log "--- Finished: Factory CLI Installation ---"
}

configure_factory() {
    log "--- Starting: Factory CLI Configuration ---"
    # Pass env vars into the subshell for the config
    # FIX: Removed `local` keyword from the script string
    as_user '
        set -e
        config_dir="$HOME/.factory"
        config_file="$config_dir/config.json"
        mkdir -p "$config_dir"
        echo "Writing Factory config to $config_file..."
        # Use cat to safely create the JSON config
        cat > "$config_file" << EOF
{
  "api_key": "'"$FACTORY_API_KEY"'",
  "custom_models": [
    {
      "model_display_name": "GLM 4.6 Coding Plan",
      "model": "glm-4.6",
      "base_url": "https://api.z.ai/api/anthropic",
      "api_key": "'"$ZAI_API_KEY"'",
      "provider": "zai"
    }
  ]
}
EOF
        echo "Factory config file created/updated."
    '
    log "--- Finished: Factory CLI Configuration ---"
}

setup_workspace() {
    log "--- Starting: Workspace Setup ---"
    local code_dir="$REAL_HOME/code"
    if [[ ! -d "$code_dir" ]]; then
        mkdir -p "$code_dir"
        chown "$REAL_USER:$REAL_USER" "$code_dir"
        log "Created workspace directory at $code_dir."
    else
        log "Workspace directory $code_dir already exists."
    fi
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

    SCRIPT_COMPLETED=true
    
    log "${GREEN}===============================================${NC}"
    log "${GREEN}          SETUP COMPLETE! 🎉          ${NC}"
    log "${GREEN}===============================================${NC}"
    log "Development environment configured for user: ${GREEN}$REAL_USER${NC}"
    log ""
    log "${YELLOW}IMPORTANT:${NC} For PATH changes to take effect, you must:"
    log "  1. ${CYAN}Exit this shell session.${NC}"
    log "  2. ${CYAN}Start a new one.${NC}"
    log "  (or run 'source $REAL_HOME/.bashrc' in your existing shell)"
    log ""
    log "Then you can run commands like ${YELLOW}bun${NC}, ${YELLOW}gh${NC}, and ${YELLOW}droid${NC}."
}

# Run it
main
