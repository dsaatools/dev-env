#!/usr/bin/env bash
# Fail on any error, unbound variable, or pipe failure
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
error() { echo -e "${RED}[ERROR]${NC} $*" >&2; exit 1; }

# Graceful exit trap
trap 'error "Script exited prematurely on line $LINENO."' ERR

# --- Script Initialization ---
log "Initializing script..."
# Script must run as root to manage packages, but it operates on behalf of a user.
if [[ $EUID -ne 0 ]] || [[ -z "${SUDO_USER:-}" ]]; then
    error "This script must be run with sudo (e.g., 'sudo bash -c \"...\"')."
fi

REAL_USER=$SUDO_USER
REAL_HOME=$(getent passwd "$REAL_USER" | cut -d: -f6)
log "Running as root on behalf of user: ${GREEN}$REAL_USER${NC} (home: $REAL_HOME)"

# --- Functions ---

run_as_user() {
    sudo -u "$REAL_USER" HOME="$REAL_HOME" "$@"
}

check_env() {
    log "--- Starting: Environment Check ---"
    local required=("GITHUB_TOKEN" "FACTORY_API_KEY" "ZAI_API_KEY" "GIT_USER_NAME" "GIT_USER_EMAIL")
    for var in "${required[@]}"; do
        # Use parameter expansion to check if var is unset or empty
        if [[ -z "${!var:-}" ]]; then
            error "$var is required. Set it in .env or export before running."
        fi
    done
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
    # Use --no-install-recommends to keep the environment lean.
    apt-get install -y --no-install-recommends "${packages[@]}"
    log "--- Finished: System Package Installation ---"
}

setup_git() {
    log "--- Starting: Git Configuration ---"
    run_as_user bash -c "
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
    run_as_user bash -s <<'EOF'
        set -euo pipefail
        export BUN_INSTALL="$HOME/.bun"
        export PATH="$BUN_INSTALL/bin:$PATH"

        if command -v bun &>/dev/null; then
            echo "Bun is already installed (version: $(bun --version)). Updating..."
            bun upgrade
        else
            echo "Installing Bun JS runtime..."
            curl -fsSL https://bun.sh/install | bash
        fi

        # Ensure Bun is in the shell profile for subsequent sessions
        if ! grep -q 'export BUN_INSTALL' "$HOME/.bashrc"; then
            echo -e '\n# Bun JS Runtime\nexport BUN_INSTALL="$HOME/.bun"\nexport PATH="$BUN_INSTALL/bin:$PATH"' >> "$HOME/.bashrc"
            echo "Bun environment variables added to ~/.bashrc"
        fi
EOF
    error "Bun installation failed."
    log "--- Finished: Bun Installation ---"
}

install_claude() {
    log "--- Starting: Claude Code CLI Installation ---"
    run_as_user bash -s <<'EOF'
        set -euo pipefail
        export BUN_INSTALL="$HOME/.bun"
        export PATH="$BUN_INSTALL/bin:$PATH"

        if bun pm ls -g | grep -q "@anthropic-ai/claude-code"; then
            echo "Claude Code CLI is already installed."
        else
            echo "Installing @anthropic-ai/claude-code globally..."
            bun install -g @anthropic-ai/claude-code
        fi
EOF
    error "Claude Code CLI installation failed."
    log "--- Finished: Claude Code CLI Installation ---"
}

setup_gh() {
    log "--- Starting: GitHub CLI Setup ---"
    # Pass GITHUB_TOKEN to the subshell via an env var with a different name
    # to avoid gh's built-in check that prevents stdin login when GITHUB_TOKEN is set.
    sudo -u "$REAL_USER" HOME="$REAL_HOME" GH_CLI_TOKEN="$GITHUB_TOKEN" bash -s <<'EOF'
        set -euo pipefail
        echo "Authenticating GitHub CLI..."

        # The gh CLI fails if GITHUB_TOKEN is in the env when logging in via stdin.
        # Unsetting it forces it to read from stdin, where we pipe the token.
        (unset GITHUB_TOKEN; echo "$GH_CLI_TOKEN" | gh auth login --with-token --hostname github.com)

        gh config set git_protocol https
        echo "GitHub CLI authenticated and configured successfully."
EOF
    error "GitHub CLI authentication failed."
    log "--- Finished: GitHub CLI Setup ---"
}

install_factory() {
    log "--- Starting: Factory CLI (droid) Installation ---"
    run_as_user bash -s <<'EOF'
        set -euo pipefail
        export FACTORY_INSTALL="$HOME/.local"
        export PATH="$FACTORY_INSTALL/bin:$PATH"

        if command -v droid &>/dev/null; then
            echo "Factory CLI (droid) is already installed. Checking for updates..."
            # Assuming `droid update` is the command, or re-running installer might be idempotent
            curl -fsSL https://app.factory.ai/cli | sh
        else
            echo "Installing Factory CLI (droid)..."
            curl -fsSL https://app.factory.ai/cli | sh
        fi

        if ! grep -q ".local/bin" "$HOME/.bashrc"; then
            echo -e '\n# Factory CLI (droid) Path\nexport PATH="$HOME/.local/bin:$PATH"' >> "$HOME/.bashrc"
            echo "Factory CLI path added to ~/.bashrc"
        fi
EOF
    error "Factory CLI installation failed."
    log "--- Finished: Factory CLI Installation ---"
}

configure_factory() {
    log "--- Starting: Factory CLI Configuration ---"
    # Pass API keys as env vars to the subshell started by sudo.
    # Using a heredoc avoids nested quoting issues entirely.
    sudo -u "$REAL_USER" HOME="$REAL_HOME" \
        FACTORY_API_KEY="$FACTORY_API_KEY" ZAI_API_KEY="$ZAI_API_KEY" \
        bash -s <<'EOF'
        set -euo pipefail
        local config_dir="$HOME/.factory"
        local config_file="$config_dir/config.json"
        mkdir -p "$config_dir"

        echo "Writing Factory config to $config_file..."
        # Use jq to safely build the JSON config from environment variables
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
EOF
    error "Factory CLI configuration failed."
    log "--- Finished: Factory CLI Configuration ---"
}

setup_workspace() {
    log "--- Starting: Workspace Setup ---"
    run_as_user bash -s <<'EOF'
        set -euo pipefail
        local code_dir="$HOME/code"
        if [[ ! -d "$code_dir" ]]; then
            mkdir -p "$code_dir"
            echo "Created workspace directory at ~/code."
        else
            echo "Workspace directory ~/code already exists."
        fi
EOF
    error "Workspace setup failed."
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

    log "${GREEN}===============================================${NC}"
    log "${GREEN}          SETUP COMPLETE! 🎉          ${NC}"
    log "${GREEN}===============================================${NC}"
    log "To apply all changes, please start a new shell or run:"
    log "${YELLOW}source $REAL_HOME/.bashrc${NC}"

    # Unset the trap on a successful run
    trap - ERR
}

# Engage!
main
