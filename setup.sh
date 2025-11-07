#!/usr/bin/env bash
#
# Final, robust setup script for dsaatools development environment.
# Fixes PATH issues and ensures commands run as the correct user.
#

# --- Configuration & Safety ---
# Fail on any error, unbound variable, or pipe failure
set -euo pipefail

# Colors for cleaner output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
NC='\033[0m'

# --- Logging and Error Handling ---
log()  { echo -e "${CYAN}[$(date +'%H:%M:%S')]${NC} $*"; }
warn() { echo -e "${YELLOW}[WARN]${NC} $*"; }
die()  { echo -e "${RED}[ERROR]${NC} $*" >&2; exit 1; }

# Trap to catch errors and exit gracefully
SCRIPT_COMPLETED=false
trap '[[ "$SCRIPT_COMPLETED" == false ]] && die "Script exited prematurely on line $LINENO."' ERR

# --- Script Initialization: Detect the real user ---
log "Initializing script..."

if [[ $EUID -eq 0 ]] && [[ -n "${SUDO_USER:-}" ]]; then
    # Script is run with sudo by a user
    REAL_USER="$SUDO_USER"
    REAL_HOME=$(getent passwd "$REAL_USER" | cut -d: -f6)
    log "Running as root on behalf of user: ${GREEN}$REAL_USER${NC} (home: $REAL_HOME)"
elif [[ $EUID -eq 0 ]]; then
    # Script is run as root directly (e.g., in a container)
    REAL_USER="root"
    REAL_HOME="/root"
    log "Running as root. Target user set to ${GREEN}root${NC} (home: $REAL_HOME)"
else
    # Script is run as a normal user, no sudo
    REAL_USER=$(whoami)
    REAL_HOME=$HOME
    log "Running as current user: ${GREEN}$REAL_USER${NC} (home: $REAL_HOME)"
    warn "Not running as root. System package installation will likely fail."
    warn "Please run with: curl ... | sudo bash -c '...'"
fi

# Define the user's bash profile file
BASHRC="$REAL_HOME/.bashrc"

# --- Helper Functions ---

# Run a command as the REAL_USER
as_real_user() {
    if [[ "$(whoami)" == "$REAL_USER" ]]; then
        # Already the right user, just execute in a bash subshell
        bash -c "$1"
    else
        # Use sudo to switch to the right user
        sudo -u "$REAL_USER" HOME="$REAL_HOME" bash -c "$1"
    fi
}

# Add a line to a file if it doesn't already exist
append_if_missing() {
    local line="$1"
    local file="$2"
    if ! grep -qF -- "$line" "$file" 2>/dev/null; then
        echo "$line" >> "$file"
    fi
}

# --- Main Functions ---

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
        die "Missing required environment variables: ${missing[*]}. Set them in .env or export them."
    fi
    log "All required environment variables are present."
    log "--- Finished: Environment Check ---"
}

install_packages() {
    log "--- Starting: System Package Installation ---"
    if [[ $EUID -ne 0 ]]; then
        warn "Not root, skipping system package installation."
        log "--- Finished: System Package Installation ---"
        return
    fi
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
    as_real_user "
        git config --global user.name '$GIT_USER_NAME'
        git config --global user.email '$GIT_USER_EMAIL'
        git config --global init.defaultBranch main
    "
    log "Git configured globally for user '$GIT_USER_NAME'."
    log "--- Finished: Git Configuration ---"
}

install_bun() {
    log "--- Starting: Bun Installation ---"
    # Define Bun paths for the target user
    local BUN_INSTALL_DIR="$REAL_HOME/.bun"
    local BUN_BIN="$BUN_INSTALL_DIR/bin/bun"

    # Persistently set environment variables for the user
    append_if_missing '' "$BASHRC"
    append_if_missing '# Bun JS Runtime' "$BASHRC"
    append_if_missing "export BUN_INSTALL=\"\$HOME/.bun\"" "$BASHRC"
    append_if_missing "export PATH=\"\$BUN_INSTALL/bin:\$PATH\"" "$BASHRC"

    # Run installation as the target user
    as_real_user "
        set -e
        export BUN_INSTALL=\"\$HOME/.bun\"
        export PATH=\"\$BUN_INSTALL/bin:\$PATH\"
        if [[ -f \"\$BUN_INSTALL/bin/bun\" ]]; then
            echo \"Bun is already installed. Updating...\"
            \$BUN_INSTALL/bin/bun upgrade
        else
            echo \"Installing Bun JS runtime...\"
            curl -fsSL https://bun.sh/install | bash
        fi
    "
    log "--- Finished: Bun Installation ---"
}

install_claude() {
    log "--- Starting: Claude Code CLI Installation ---"
    as_real_user "
        set -e
        export BUN_INSTALL=\"\$HOME/.bun\"
        export PATH=\"\$BUN_INSTALL/bin:\$PATH\"
        if ! command -v bun &>/dev/null; then
            die 'Bun command not found in user PATH, cannot install Claude CLI.'
        fi
        if ! bun pm ls -g 2>/dev/null | grep -q '@anthropic-ai/claude-code'; then
            echo 'Installing @anthropic-ai/claude-code globally...'
            bun install -g @anthropic-ai/claude-code
        else
            echo 'Claude Code CLI is already installed.'
        fi
    "
    log "--- Finished: Claude Code CLI Installation ---"
}

setup_gh() {
    log "--- Starting: GitHub CLI Setup ---"
    as_real_user "
        set -e
        echo 'Authenticating GitHub CLI non-interactively...'
        echo '$GITHUB_TOKEN' | gh auth login --with-token --hostname github.com
        gh config set git_protocol https
        echo 'GitHub CLI authenticated and configured successfully.'
    "
    log "--- Finished: GitHub CLI Setup ---"
}

install_factory() {
    log "--- Starting: Factory CLI (droid) Installation ---"
    local DROID_BIN="$REAL_HOME/.local/bin/droid"

    # Persistently set PATH for the user
    append_if_missing '' "$BASHRC"
    append_if_missing '# Factory CLI (droid) Path' "$BASHRC"
    append_if_missing "export PATH=\"\$HOME/.local/bin:\$PATH\"" "$BASHRC"

    as_real_user "
        set -e
        export PATH=\"\$HOME/.local/bin:\$PATH\" # Set for this subshell
        if [[ -f \"$DROID_BIN\" ]]; then
            echo 'Factory CLI (droid) is already installed.'
        else
            echo 'Installing Factory CLI (droid)...'
            curl -fsSL https://app.factory.ai/cli | sh
        fi
    "
    log "--- Finished: Factory CLI Installation ---"
}

configure_factory() {
    log "--- Starting: Factory CLI Configuration ---"
    as_real_user "
        set -e
        config_dir=\"\$HOME/.factory\"
        config_file=\"\$config_dir/config.json\"
        mkdir -p \"\$config_dir\"
        echo \"Writing Factory config to \$config_file...\"
        # Use cat with a HEREDOC to safely create the JSON
        cat > \"\$config_file\" << EOF
{
  \"api_key\": \"$FACTORY_API_KEY\",
  \"custom_models\": [
    {
      \"model_display_name\": \"GLM 4.6 Coding Plan\",
      \"model\": \"glm-4.6\",
      \"base_url\": \"https://api.z.ai/api/anthropic\",
      \"api_key\": \"$ZAI_API_KEY\",
      \"provider\": \"zai\"
    }
  ]
}
EOF
        echo \"Factory config file created/updated.\"
        echo \"Config content (without keys):\"
        grep -v '\"api_key\"' \"\$config_file\" || true
    "
    log "--- Finished: Factory CLI Configuration ---"
}

setup_workspace() {
    log "--- Starting: Workspace Setup ---"
    as_real_user "
        mkdir -p \"\$HOME/code\"
    "
    log "Workspace directory ~/code is present."
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
    log "${GREEN}           SETUP COMPLETE! 🎉          ${NC}"
    log "${GREEN}===============================================${NC}"
    log "Environment has been configured for user: ${GREEN}$REAL_USER${NC}"
    log ""
    log "${YELLOW}IMPORTANT:${NC} To apply the changes, you must either:"
    log "  1. Close this terminal and open a new one."
    log "  2. Or run: ${GREEN}source $BASHRC${NC}"
    log ""
    log "After that, you can verify the installations:"
    log "  - bun --version"
    log "  - droid --version"
    log "  - gh auth status"
}

# Run the main function
main
