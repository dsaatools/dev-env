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
# Check if running with sudo
if [[ $EUID -eq 0 ]] && [[ -n "${SUDO_USER:-}" ]]; then
    REAL_USER=$SUDO_USER
    REAL_HOME=$(getent passwd "$REAL_USER" | cut -d: -f6)
    log "Running as root on behalf of user: ${GREEN}$REAL_USER${NC} (home: $REAL_HOME)"
else
    REAL_USER=$(whoami)
    REAL_HOME=$HOME
    log "Running as current user: ${GREEN}$REAL_USER${NC} (home: $REAL_HOME)"
    warn "Some operations may require sudo privileges"
fi

# Define key paths
export BUN_INSTALL="$REAL_HOME/.bun"
export PATH="$BUN_INSTALL/bin:$PATH"

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
        error "Missing required environment variables: ${missing[*]}. Set them in .env or export before running."
    fi
    log "All required environment variables are present."
    log "--- Finished: Environment Check ---"
}

install_packages() {
    log "--- Starting: System Package Installation ---"
    export DEBIAN_FRONTEND=noninteractive
    
    if command -v apt-get >/dev/null 2>&1; then
        log "Updating package lists..."
        apt-get update -qq

        local packages=("curl" "unzip" "htop" "tmux" "nodejs" "git" "jq" "gh")
        log "Installing required packages: ${packages[*]}..."
        apt-get install -y "${packages[@]}"
    else
        warn "apt-get not found, skipping system package installation"
    fi
    
    log "--- Finished: System Package Installation ---"
}

setup_git() {
    log "--- Starting: Git Configuration ---"
    # Run git config as the target user
    if [[ "$(whoami)" != "$REAL_USER" ]]; then
        sudo -u "$REAL_USER" bash -c "
            git config --global user.name '$GIT_USER_NAME'
            git config --global user.email '$GIT_USER_EMAIL'
            git config --global init.defaultBranch main
        "
    else
        git config --global user.name "$GIT_USER_NAME"
        git config --global user.email "$GIT_USER_EMAIL"
        git config --global init.defaultBranch main
    fi
    log "Git configured globally for user '$GIT_USER_NAME'."
    log "--- Finished: Git Configuration ---"
}

install_bun() {
    log "--- Starting: Bun Installation ---"
    
    local bun_install_cmd='
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
        
        # Add to shell profile for future sessions
        if ! grep -q "BUN_INSTALL" "$HOME/.bashrc" 2>/dev/null; then
            echo "" >> "$HOME/.bashrc"
            echo "# Bun JS Runtime" >> "$HOME/.bashrc"
            echo "export BUN_INSTALL=\"\$HOME/.bun\"" >> "$HOME/.bashrc"
            echo "export PATH=\"\$BUN_INSTALL/bin:\$PATH\"" >> "$HOME/.bashrc"
            echo "Bun environment variables added to ~/.bashrc"
        fi
    '
    
    if [[ "$(whoami)" != "$REAL_USER" ]]; then
        sudo -u "$REAL_USER" HOME="$REAL_HOME" bash -c "$bun_install_cmd"
    else
        bash -c "$bun_install_cmd"
    fi
    
    log "--- Finished: Bun Installation ---"
}

install_claude() {
    log "--- Starting: Claude Code CLI Installation ---"
    
    local claude_install_cmd='
        set -e
        export BUN_INSTALL="$HOME/.bun"
        export PATH="$BUN_INSTALL/bin:$PATH"
        
        if ! command -v bun &>/dev/null; then
            echo "Bun not found, cannot install Claude Code CLI"
            exit 1
        fi
        
        if ! bun pm ls -g 2>/dev/null | grep -q "@anthropic-ai/claude-code"; then
            echo "Installing @anthropic-ai/claude-code globally..."
            bun install -g @anthropic-ai/claude-code
        else
            echo "Claude Code CLI is already installed."
        fi
    '
    
    if [[ "$(whoami)" != "$REAL_USER" ]]; then
        sudo -u "$REAL_USER" HOME="$REAL_HOME" bash -c "$claude_install_cmd"
    else
        bash -c "$claude_install_cmd"
    fi
    
    log "--- Finished: Claude Code CLI Installation ---"
}

setup_gh() {
    log "--- Starting: GitHub CLI Setup ---"
    
    local gh_setup_cmd='
        set -e
        echo "Authenticating GitHub CLI..."
        
        # Use a different variable name to avoid conflict with GITHUB_TOKEN env var
        GH_AUTH_TOKEN="'"$GITHUB_TOKEN"'"
        echo "$GH_AUTH_TOKEN" | gh auth login --with-token --hostname github.com
        
        gh config set git_protocol https
        echo "GitHub CLI authenticated and configured successfully."
    '
    
    if [[ "$(whoami)" != "$REAL_USER" ]]; then
        sudo -u "$REAL_USER" HOME="$REAL_HOME" bash -c "$gh_setup_cmd"
    else
        bash -c "$gh_setup_cmd"
    fi
    
    log "--- Finished: GitHub CLI Setup ---"
}

install_factory() {
    log "--- Starting: Factory CLI (droid) Installation ---"
    
    local factory_install_cmd='
        set -e
        export FACTORY_INSTALL="$HOME/.local"
        export PATH="$FACTORY_INSTALL/bin:$PATH"

        if ! command -v droid &>/dev/null; then
            echo "Installing Factory CLI (droid)..."
            curl -fsSL https://app.factory.ai/cli | sh
            
            # Ensure PATH is set for current session
            export PATH="$HOME/.local/bin:$PATH"
            
            if ! grep -q ".local/bin" "$HOME/.bashrc" 2>/dev/null; then
                echo "" >> "$HOME/.bashrc"
                echo "# Factory CLI (droid) Path" >> "$HOME/.bashrc"
                echo "export PATH=\"\$HOME/.local/bin:\$PATH\"" >> "$HOME/.bashrc"
                echo "Factory CLI path added to ~/.bashrc"
            fi
        else
            echo "Factory CLI (droid) is already installed."
        fi
    '
    
    if [[ "$(whoami)" != "$REAL_USER" ]]; then
        sudo -u "$REAL_USER" HOME="$REAL_HOME" bash -c "$factory_install_cmd"
    else
        bash -c "$factory_install_cmd"
    fi
    
    log "--- Finished: Factory CLI Installation ---"
}

configure_factory() {
    log "--- Starting: Factory CLI Configuration ---"
    
    local factory_config_cmd='
        set -e
        config_dir="$HOME/.factory"
        config_file="$config_dir/config.json"
        mkdir -p "$config_dir"
        
        echo "Writing Factory config to $config_file..."
        
        # Use cat to safely create the JSON config without variable expansion issues
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
        
        echo "Factory config file created/updated at $config_file"
        echo "Config content (without keys):"
        grep -v "api_key" "$config_file" || true
    '
    
    if [[ "$(whoami)" != "$REAL_USER" ]]; then
        sudo -u "$REAL_USER" HOME="$REAL_HOME" bash -c "$factory_config_cmd"
    else
        bash -c "$factory_config_cmd"
    fi
    
    log "--- Finished: Factory CLI Configuration ---"
}

setup_workspace() {
    log "--- Starting: Workspace Setup ---"
    
    local workspace_cmd='
        set -e
        code_dir="$HOME/code"
        if [[ ! -d "$code_dir" ]]; then
            mkdir -p "$code_dir"
            echo "Created workspace directory at ~/code."
        else
            echo "Workspace directory ~/code already exists."
        fi
    '
    
    if [[ "$(whoami)" != "$REAL_USER" ]]; then
        sudo -u "$REAL_USER" HOME="$REAL_HOME" bash -c "$workspace_cmd"
    else
        bash -c "$workspace_cmd"
    fi
    
    log "--- Finished: Workspace Setup ---"
}

reload_shell() {
    log "--- Reloading Shell Environment ---"
    if [[ -f "$REAL_HOME/.bashrc" ]]; then
        log "Loading updated environment from ~/.bashrc"
        # Source the bashrc for the target user
        if [[ "$(whoami)" != "$REAL_USER" ]]; then
            sudo -u "$REAL_USER" HOME="$REAL_HOME" bash -c "source '$REAL_HOME/.bashrc'"
        else
            source "$REAL_HOME/.bashrc"
        fi
    fi
    log "--- Finished Reloading Shell Environment ---"
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
    reload_shell

    # Set completion flag to prevent error trap on successful exit
    SCRIPT_COMPLETED=true
    
    log "${GREEN}===============================================${NC}"
    log "${GREEN}          SETUP COMPLETE! 🎉          ${NC}"
    log "${GREEN}===============================================${NC}"
    log "Development environment has been configured for:"
    log "  - User: ${GREEN}$REAL_USER${NC}"
    log "  - Home: ${GREEN}$REAL_HOME${NC}"
    log ""
    log "Installed tools:"
    log "  ${GREEN}✓${NC} System packages (curl, unzip, git, nodejs, etc.)"
    log "  ${GREEN}✓${NC} Bun JS runtime"
    log "  ${GREEN}✓${NC} Claude Code CLI"
    log "  ${GREEN}✓${NC} GitHub CLI (authenticated)"
    log "  ${GREEN}✓${NC} Factory CLI (droid) with ZAI model configured"
    log "  ${GREEN}✓${NC} Workspace directory (~/code)"
    log ""
    log "Next steps:"
    log "  - Run ${YELLOW}droid${NC} to start using Factory CLI"
    log "  - Use ${YELLOW}/model${NC} in droid to select GLM 4.6 model"
    log "  - Start coding in ${YELLOW}~/code${NC} directory"
}

# Run the main function
main
