#!/usr/bin/env bash
# WARNING: Piping curl to bash is a security risk. Inspect this script before running.
set -euo pipefail

# --- Config ---
# Pin package versions for reproducibility. Adjust for your distro if needed.
GIT_VERSION="1:2.39.*"
NODE_VERSION="18.*"

# --- Colors & Logging ---
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

log() { echo -e "${GREEN}[$(date +'%H:%M:%S')]${NC} $*"; }
warn() { echo -e "${YELLOW}[WARN]${NC} $*"; }
error() { echo -e "${RED}[ERROR]${NC} $*"; exit 1; }

# --- Environment ---
# Source .env if it exists, exporting all variables.
# `set -a` auto-exports variables; `set +a` disables it.
[[ -f .env ]] && set -a && source .env && set +a

# Check required env vars
check_env() {
    local required=("GITHUB_TOKEN" "FACTORY_API_KEY" "ZAI_API_KEY" "GIT_USER_NAME" "GIT_USER_EMAIL")
    for var in "${required[@]}"; do
        [[ -z "${!var:-}" ]] && error "$var is required. Set it in .env or export before running."
    done
    
    # Optional multiple tokens
    if [[ -n "${GITHUB_TOKENS:-}" ]]; then
        IFS=',' read -ra TOKENS <<< "$GITHUB_TOKENS"
        log "Found ${#TOKENS[@]} additional GitHub tokens"
    fi
}

# --- System Packages ---
install_packages() {
    log "Installing system packages..."
    export DEBIAN_FRONTEND=noninteractive
    apt-get update -qq
    # Pinning versions for stability. Comment out if it causes issues on your OS.
    apt-get install -y --no-install-recommends curl unzip htop tmux git="${GIT_VERSION}" nodejs="${NODE_VERSION}"
}

# --- Bun ---
install_bun() {
    log "Installing bun..."
    if ! command -v bun &> /dev/null; then
        curl -fsSL https://bun.sh/install | bash
        # Sourcing for immediate use in this script
        export BUN_INSTALL="$HOME/.bun"
        export PATH="$BUN_INSTALL/bin:$PATH"
        # Persist for future shells
        echo 'export BUN_INSTALL="$HOME/.bun"' >> ~/.bashrc
        echo 'export PATH="$BUN_INSTALL/bin:$PATH"' >> ~/.bashrc
    else
        log "bun already installed"
    fi
}

# --- Claude Code ---
install_claude() {
    log "Installing claude-code..."
    # Pinning to a specific version is recommended for CI/CD, e.g., @anthropic-ai/claude@0.4.12
    bun install -g @anthropic-ai/claude-code
}

# --- Git ---
setup_git() {
    log "Configuring git..."
    local current_name current_email
    current_name=$(git config --global --get user.name || echo "")
    current_email=$(git config --global --get user.email || echo "")

    if [[ -n "$current_name" || -n "$current_email" ]]; then
        warn "Git user is already configured as '$current_name <$current_email>'. Overwriting."
    fi

    git config --global user.name "$GIT_USER_NAME"
    git config --global user.email "$GIT_USER_EMAIL"
    git config --global init.defaultBranch main
    git config --global pull.rebase false
    log "Git configured for $GIT_USER_NAME <$GIT_USER_EMAIL>"
}

# --- GitHub CLI ---
setup_gh() {
    log "Setting up GitHub CLI..."
    if ! command -v gh &> /dev/null; then
        log "Installing gh..."
        curl -fsSL https://cli.github.com/packages/githubcli-archive-keyring.gpg | dd of=/usr/share/keyrings/githubcli-archive-keyring.gpg
        echo "deb [arch=$(dpkg --print-architecture) signed-by=/usr/share/keyrings/githubcli-archive-keyring.gpg] https://cli.github.com/packages stable main" | tee /etc/apt/sources.list.d/github-cli.list > /dev/null
        apt-get update -qq
        apt-get install -y gh
    else
        log "gh already installed"
    fi

    if ! gh auth status &> /dev/null; then
        log "Authenticating with primary GitHub account..."
        echo "$GITHUB_TOKEN" | gh auth login --with-token --hostname github.com
        gh config set git_protocol https
    else
        log "Already authenticated with GitHub."
    fi
    
    # Store additional tokens for later use
    if [[ -n "${GITHUB_TOKENS:-}" ]]; then
        mkdir -p ~/.config/gh/tokens
        IFS=',' read -ra TOKENS <<< "$GITHUB_TOKENS"
        for i in "${!TOKENS[@]}"; do
            local token="${TOKENS[$i]}"
            local token_file="$HOME/.config/gh/tokens/token_$((i+2))"
            echo "$token" > "$token_file"
            chmod 600 "$token_file"
            log "Stored additional GitHub token $((i+2))"
        done
        
        # Add helper functions to .bashrc if not already present
        if ! grep -q "gh-switch()" ~/.bashrc; then
            cat >> ~/.bashrc << 'EOF'

# GitHub account switcher
gh-switch() {
    local account_num=${1:-1}
    if [[ $account_num -eq 1 ]]; then
        echo "$GITHUB_TOKEN" | gh auth login --with-token --hostname github.com
        echo "Switched to primary GitHub account"
    elif [[ -f "$HOME/.config/gh/tokens/token_$account_num" ]]; then
        local token=$(cat "$HOME/.config/gh/tokens/token_$account_num")
        echo "$token" | gh auth login --with-token --hostname github.com
        echo "Switched to GitHub account $account_num"
    else
        echo "Token for account $account_num not found"
        return 1
    fi
}

# List available GitHub accounts
gh-list() {
    echo "Available GitHub accounts:"
    echo "1: Primary"
    for token_file in "$HOME"/.config/gh/tokens/token_*; do
        if [[ -f "$token_file" ]]; then
            local num=$(basename "$token_file" | cut -d'_' -f2)
            echo "$num: Additional"
        fi
    done
}
EOF
        fi
    fi
}

# --- Factory AI ---
install_factory() {
    log "Installing Factory CLI..."
    if ! command -v factory &> /dev/null; then
        # WARNING: Another curl | sh. Review the script at the URL if you're concerned.
        curl -fsSL https://app.factory.ai/cli | sh
        echo 'export PATH="$HOME/.local/bin:$PATH"' >> ~/.bashrc
        export PATH="$HOME/.local/bin:$PATH"
    else
        log "Factory CLI already installed"
    fi
}

configure_factory() {
    log "Configuring Factory CLI..."
    local config_dir="$HOME/.factory"
    local config_file="$config_dir/config.json"

    if [[ -f "$config_file" ]]; then
        warn "Factory config already exists at $config_file. Backing up to $config_file.bak"
        cp "$config_file" "$config_file.bak"
    fi
    
    mkdir -p "$config_dir"
    
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
}

# --- Workspace ---
setup_workspace() {
    log "Setting up workspace..."
    mkdir -p ~/code
    # Note: Not changing directory here. The user should `cd ~/code` themselves.
}

# --- Main ---
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
    
    log "Setup complete. This script is idempotent; you can run it again safely."
    log "Run 'source ~/.bashrc' to reload your shell environment."
    log "Workspace ready at ~/code"
    [[ -n "${GITHUB_TOKENS:-}" ]] && log "Use 'gh-switch <num>' and 'gh-list' to manage GitHub accounts."
}

main "$@"
