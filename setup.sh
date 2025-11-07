#!/usr/bin/env bash
set -euo pipefail

# --- Configuration ---
# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

# --- Helper Functions ---
log() { echo -e "${GREEN}[$(date +'%H:%M:%S')]${NC} $*"; }
warn() { echo -e "${YELLOW}[WARN]${NC} $*"; }
error() { echo -e "${RED}[ERROR]${NC} $*"; exit 1; }

# --- Environment Setup ---
# Determine user context (root vs. regular user)
if [[ $EUID -eq 0 ]]; then
    log "Running as root for system package installation"
    SYSTEM_INSTALL=true
    REAL_USER=${SUDO_USER:-$USER}
    REAL_HOME=$(getent passwd "$REAL_USER" | cut -d: -f6)
else
    log "Running as user for user-specific installations"
    SYSTEM_INSTALL=false
    REAL_USER=$USER
    REAL_HOME=$HOME
fi

# Function to pass helper definitions to sub-shells (Fix for 'log: command not found')
declare_helpers() {
    declare -f log warn error
}

# --- Pre-flight Checks ---
check_env() {
    log "Checking required environment variables..."
    local required=("GITHUB_TOKEN" "FACTORY_API_KEY" "ZAI_API_KEY" "GIT_USER_NAME" "GIT_USER_EMAIL")
    for var in "${required[@]}"; do
        [[ -z "${!var:-}" ]] && error "$var is required. Set it in .env or export before running."
    done

    if [[ -n "${GITHUB_TOKENS:-}" ]]; then
        IFS=',' read -ra TOKENS <<< "$GITHUB_TOKENS"
        log "Found ${#TOKENS[@]} additional GitHub tokens."
    fi
}

# --- Installation & Configuration Functions ---

install_packages() {
    if [[ "$SYSTEM_INSTALL" != true ]]; then
        log "Skipping system package installation (not running as root)."
        return
    fi

    log "Updating package lists and checking system packages..."
    export DEBIAN_FRONTEND=noninteractive
    apt-get update -qq

    local packages=("curl" "unzip" "htop" "tmux" "nodejs" "git" "jq")
    for package in "${packages[@]}"; do
        if ! dpkg -l | grep -q "^ii *$package "; then
            log "Installing $package..."
            apt-get install -y "$package"
        else
            log "$package is already installed."
        fi
    done
}

install_bun() {
    # This script block will be executed as the REAL_USER
    local script_to_run="
        export HOME=\"$REAL_HOME\"
        log \"Checking bun installation...\"
        if ! command -v bun &> /dev/null; then
            log \"Installing bun...\"
            # FIX: Export BUN_INSTALL *before* running the installer
            export BUN_INSTALL=\"\$HOME/.bun\"
            curl -fsSL https://bun.sh/install | bash
            
            if ! grep -q 'BUN_INSTALL' \"\$HOME/.bashrc\"; then
                echo '' >> \"\$HOME/.bashrc\"
                echo '# Bun JS Runtime' >> \"\$HOME/.bashrc\"
                echo 'export BUN_INSTALL=\"\$HOME/.bun\"' >> \"\$HOME/.bashrc\"
                echo 'export PATH=\"\$BUN_INSTALL/bin:\$PATH\"' >> \"\$HOME/.bashrc\"
            fi
        else
            log \"bun is already installed.\"
        fi
    "
    if [[ "$SYSTEM_INSTALL" == true ]]; then
        sudo -u "$REAL_USER" bash -c "$(declare_helpers); $script_to_run"
    else
        bash -c "$(declare_helpers); $script_to_run"
    fi
}

install_claude() {
    local script_to_run="
        export HOME=\"$REAL_HOME\"
        export PATH=\"\$HOME/.bun/bin:\$PATH\" # Ensure bun is in the PATH
        log \"Checking claude-code installation...\"
        if ! bun pm ls -g | grep -q \"@anthropic-ai/claude-code\"; then
            log \"Installing claude-code...\"
            bun install -g @anthropic-ai/claude-code
        else
            log \"claude-code is already installed.\"
        fi
    "
    if [[ "$SYSTEM_INSTALL" == true ]]; then
        sudo -u "$REAL_USER" bash -c "$(declare_helpers); $script_to_run"
    else
        bash -c "$(declare_helpers); $script_to_run"
    fi
}

setup_git() {
    local script_to_run="
        export HOME=\"$REAL_HOME\"
        log \"Configuring git...\"
        git config --global user.name \"$GIT_USER_NAME\"
        git config --global user.email \"$GIT_USER_EMAIL\"
        git config --global init.defaultBranch main
        git config --global pull.rebase false
        log \"Git configured for $GIT_USER_NAME <$GIT_USER_EMAIL>\"
    "
    if [[ "$SYSTEM_INSTALL" == true ]]; then
        sudo -u "$REAL_USER" bash -c "$(declare_helpers); $script_to_run"
    else
        bash -c "$(declare_helpers); $script_to_run"
    fi
}

setup_gh() {
    if [[ "$SYSTEM_INSTALL" == true ]]; then
        if ! command -v gh &> /dev/null; then
            log "Installing GitHub CLI..."
            curl -fsSL https://cli.github.com/packages/githubcli-archive-keyring.gpg | dd of=/usr/share/keyrings/githubcli-archive-keyring.gpg
            chmod 644 /usr/share/keyrings/githubcli-archive-keyring.gpg
            echo "deb [arch=$(dpkg --print-architecture) signed-by=/usr/share/keyrings/githubcli-archive-keyring.gpg] https://cli.github.com/packages stable main" | tee /etc/apt/sources.list.d/github-cli.list > /dev/null
            apt-get update -qq
            apt-get install -y gh
        fi
    fi

    local script_to_run="
        export HOME=\"$REAL_HOME\"
        export GITHUB_TOKEN=\"$GITHUB_TOKEN\"
        export GITHUB_TOKENS=\"$GITHUB_TOKENS\"
        
        log \"Configuring GitHub CLI...\"
        echo \"\$GITHUB_TOKEN\" | gh auth login --with-token --hostname github.com
        gh config set git_protocol https
        log \"GitHub CLI authenticated with primary account.\"

        if [[ -n \"\${GITHUB_TOKENS:-}\" ]]; then
            mkdir -p \"\$HOME/.config/gh/tokens\"
            IFS=',' read -ra TOKENS <<< \"\$GITHUB_TOKENS\"
            for i in \"\${!TOKENS[@]}\"; do
                echo \"\${TOKENS[\$i]}\" > \"\$HOME/.config/gh/tokens/token_\$((i+2))\"
                chmod 600 \"\$HOME/.config/gh/tokens/token_\$((i+2))\"
            done
            
            if ! grep -q \"# GitHub account switcher\" \"\$HOME/.bashrc\"; then
                cat >> \"\$HOME/.bashrc\" << 'EOF'

# GitHub account switcher
gh-switch() {
    local account_num=\${1:-1}
    local token
    if [[ \$account_num -eq 1 ]]; then
        token="\$GITHUB_TOKEN"
        echo "Switching to primary GitHub account..."
    elif [[ -f "\$HOME/.config/gh/tokens/token_\$account_num" ]]; then
        token=\$(cat "\$HOME/.config/gh/tokens/token_\$account_num")
        echo "Switching to GitHub account \$account_num..."
    else
        echo "Error: Token for account \$account_num not found." >&2; return 1
    fi
    echo "\$token" | gh auth login --with-token --hostname github.com
}
gh-list() {
    echo "Available GitHub accounts:"
    echo "1: Primary"
    for token_file in "\$HOME"/.config/gh/tokens/token_*; do
        [[ -f "\$token_file" ]] && echo "\$(basename "\$token_file" | cut -d'_' -f2): Additional"
    done
}
EOF
                log \"Added GitHub account switcher functions to ~/.bashrc\"
            fi
        fi
    "
     if [[ "$SYSTEM_INSTALL" == true ]]; then
        sudo -u "$REAL_USER" bash -c "$(declare_helpers); $script_to_run"
    else
        bash -c "$(declare_helpers); $script_to_run"
    fi
}

install_factory() {
    local script_to_run="
        export HOME=\"$REAL_HOME\"
        log \"Checking Factory CLI installation...\"
        if ! command -v factory &> /dev/null; then
            log \"Installing Factory CLI...\"
            curl -fsSL https://app.factory.ai/cli | sh
            if ! grep -q 'factory' \"\$HOME/.bashrc\"; then
                echo '' >> \"\$HOME/.bashrc\"
                echo '# Factory AI CLI' >> \"\$HOME/.bashrc\"
                echo 'export PATH=\"\$HOME/.local/bin:\$PATH\"' >> \"\$HOME/.bashrc\"
            fi
        else
            log \"Factory CLI is already installed.\"
        fi
    "
    if [[ "$SYSTEM_INSTALL" == true ]]; then
        sudo -u "$REAL_USER" bash -c "$(declare_helpers); $script_to_run"
    else
        bash -c "$(declare_helpers); $script_to_run"
    fi
}

configure_factory() {
    # FIX: This function is rewritten to be simpler and avoid shell syntax errors.
    local script_to_run="
        export HOME=\"$REAL_HOME\"
        export FACTORY_API_KEY=\"$FACTORY_API_KEY\"
        export ZAI_API_KEY=\"$ZAI_API_KEY\"
        
        log \"Configuring Factory...\"
        local config_dir=\"\$HOME/.factory\"
        local config_file=\"\$config_dir/config.json\"
        mkdir -p \"\$config_dir\"

        # Ensure a valid base JSON file exists
        if ! jq . \"\$config_file\" &>/dev/null; then
            log \"Creating new Factory config file...\"
            echo '{\"custom_models\": []}' > \"\$config_file\"
        fi

        log \"Updating Factory API key...\"
        jq --arg key \"\$FACTORY_API_KEY\" '.api_key = \$key' \"\$config_file\" > \"\$config_file.tmp\" && mv \"\$config_file.tmp\" \"\$config_file\"

        log \"Checking for GLM model in Factory config...\"
        if jq -e '.custom_models[] | select(.model == \"glm-4.6\")' \"\$config_file\" > /dev/null; then
            log \"GLM model found. Updating its API key.\"
            jq --arg key \"\$ZAI_API_KEY\" '(.custom_models[] | select(.model == \"glm-4.6\")).api_key = \$key' \"\$config_file\" > \"\$config_file.tmp\" && mv \"\$config_file.tmp\" \"\$config_file\"
        else
            log \"GLM model not found. Adding it to configuration.\"
            jq --arg key \"\$ZAI_API_KEY\" '.custom_models += [{
                \"model_display_name\": \"GLM 4.6 Coding Plan\",
                \"model\": \"glm-4.6\",
                \"base_url\": \"https://api.z.ai/api/anthropic\",
                \"api_key\": \$key,
                \"provider\": \"zai\"
            }]' \"\$config_file\" > \"\$config_file.tmp\" && mv \"\$config_file.tmp\" \"\$config_file\"
        fi
        log \"Factory configuration is up to date.\"
    "
    if [[ "$SYSTEM_INSTALL" == true ]]; then
        sudo -u "$REAL_USER" bash -c "$(declare_helpers); $script_to_run"
    else
        bash -c "$(declare_helpers); $script_to_run"
    fi
}

setup_workspace() {
    local script_to_run="
        export HOME=\"$REAL_HOME\"
        log \"Setting up workspace directory...\"
        mkdir -p \"\$HOME/code\"
        log \"Workspace ready at \$HOME/code.\"
    "
    if [[ "$SYSTEM_INSTALL" == true ]]; then
        sudo -u "$REAL_USER" bash -c "$(declare_helpers); $script_to_run"
    else
        bash -c "$(declare_helpers); $script_to_run"
    fi
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
    
    log "Setup complete! Run 'source ~/.bashrc' or restart your terminal."
}

main "$@"
