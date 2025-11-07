#!/usr/bin/env bash
set -euo pipefail

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

log() { echo -e "${GREEN}[$(date +'%H:%M:%S')]${NC} $*"; }
warn() { echo -e "${YELLOW}[WARN]${NC} $*"; }
error() { echo -e "${RED}[ERROR]${NC} $*"; exit 1; }

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

# Install system packages
install_packages() {
    log "Checking system packages..."
    export DEBIAN_FRONTEND=noninteractive
    
    # Update package lists only if needed
    if [[ $(find /var/lib/apt/lists -mtime -1 | wc -l) -eq 0 ]]; then
        log "Updating package lists..."
        apt-get update -qq
    fi
    
    # Check and install packages one by one
    local packages=("curl" "unzip" "htop" "tmux" "nodejs" "git")
    for package in "${packages[@]}"; do
        if ! dpkg -l | grep -q "^ii  $package "; then
            log "Installing $package..."
            apt-get install -y "$package"
        else
            log "$package already installed"
        fi
    done
}

# Install bun
install_bun() {
    log "Checking bun installation..."
    if ! command -v bun &> /dev/null; then
        log "Installing bun..."
        curl -fsSL https://bun.sh/install | bash
        export BUN_INSTALL="$HOME/.bun"
        export PATH="$BUN_INSTALL/bin:$PATH"
        
        # Add to bashrc if not already there
        if ! grep -q 'export BUN_INSTALL="$HOME/.bun"' ~/.bashrc; then
            echo 'export BUN_INSTALL="$HOME/.bun"' >> ~/.bashrc
            echo 'export PATH="$BUN_INSTALL/bin:$PATH"' >> ~/.bashrc
        fi
    else
        local bun_version=$(bun --version)
        log "bun already installed (version $bun_version)"
    fi
}

# Install claude-code
install_claude() {
    log "Checking claude-code installation..."
    if ! bun pm ls -g | grep -q "@anthropic-ai/claude-code"; then
        log "Installing claude-code..."
        bun install -g @anthropic-ai/claude-code
    else
        local claude_version=$(bun pm ls -g @anthropic-ai/claude-code | grep -o '@[0-9.]*' | head -1)
        log "claude-code already installed (version ${claude_version#@})"
    fi
}

# Setup git config
setup_git() {
    log "Checking git configuration..."
    
    local current_name=$(git config --global user.name || echo "")
    local current_email=$(git config --global user.email || echo "")
    local current_default_branch=$(git config --global init.defaultBranch || echo "")
    local current_pull_rebase=$(git config --global pull.rebase || echo "")
    
    if [[ "$current_name" != "$GIT_USER_NAME" ]]; then
        log "Setting git user.name to $GIT_USER_NAME"
        git config --global user.name "$GIT_USER_NAME"
    else
        log "git user.name already set to $GIT_USER_NAME"
    fi
    
    if [[ "$current_email" != "$GIT_USER_EMAIL" ]]; then
        log "Setting git user.email to $GIT_USER_EMAIL"
        git config --global user.email "$GIT_USER_EMAIL"
    else
        log "git user.email already set to $GIT_USER_EMAIL"
    fi
    
    if [[ "$current_default_branch" != "main" ]]; then
        log "Setting git init.defaultBranch to main"
        git config --global init.defaultBranch main
    else
        log "git init.defaultBranch already set to main"
    fi
    
    if [[ "$current_pull_rebase" != "false" ]]; then
        log "Setting git pull.rebase to false"
        git config --global pull.rebase false
    else
        log "git pull.rebase already set to false"
    fi
    
    log "Git configured for $GIT_USER_NAME <$GIT_USER_EMAIL>"
}

# Setup GitHub CLI with multiple accounts
setup_gh() {
    log "Checking GitHub CLI setup..."
    
    if ! command -v gh &> /dev/null; then
        log "Installing GitHub CLI..."
        curl -fsSL https://cli.github.com/packages/githubcli-archive-keyring.gpg | dd of=/usr/share/keyrings/githubcli-archive-keyring.gpg
        echo "deb [arch=$(dpkg --print-architecture) signed-by=/usr/share/keyrings/githubcli-archive-keyring.gpg] https://cli.github.com/packages stable main" | tee /etc/apt/sources.list.d/github-cli.list > /dev/null
        apt-get update -qq
        apt-get install -y gh
    else
        local gh_version=$(gh --version | cut -d' ' -f3)
        log "GitHub CLI already installed (version $gh_version)"
    fi
    
    # Check authentication
    if ! gh auth status &> /dev/null; then
        log "Authenticating with primary GitHub account..."
        echo "$GITHUB_TOKEN" | gh auth login --with-token --hostname github.com
        gh config set git_protocol https
    else
        log "Already authenticated with GitHub"
    fi
    
    # Store additional tokens for later use
    if [[ -n "${GITHUB_TOKENS:-}" ]]; then
        mkdir -p ~/.config/gh/tokens
        IFS=',' read -ra TOKENS <<< "$GITHUB_TOKENS"
        for i in "${!TOKENS[@]}"; do
            local token="${TOKENS[$i]}"
            local token_file="$HOME/.config/gh/tokens/token_$((i+2))"
            
            if [[ ! -f "$token_file" ]]; then
                echo "$token" > "$token_file"
                chmod 600 "$token_file"
                log "Stored additional GitHub token $((i+2))"
            else
                log "GitHub token $((i+2)) already stored"
            fi
        done
        
        # Add helper functions to bashrc if not already there
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
            log "Added GitHub account switcher functions to ~/.bashrc"
        else
            log "GitHub account switcher functions already in ~/.bashrc"
        fi
    fi
}

# Install Factory CLI
install_factory() {
    log "Checking Factory CLI installation..."
    
    if ! command -v factory &> /dev/null; then
        log "Installing Factory CLI..."
        curl -fsSL https://app.factory.ai/cli | sh
        
        # Add to PATH if not already there
        if ! grep -q 'export PATH="$HOME/.local/bin:$PATH"' ~/.bashrc; then
            echo 'export PATH="$HOME/.local/bin:$PATH"' >> ~/.bashrc
        fi
        
        # Update PATH for current session
        export PATH="$HOME/.local/bin:$PATH"
    else
        local factory_version=$(factory --version 2>/dev/null | cut -d' ' -f2 || echo "unknown")
        log "Factory CLI already installed (version $factory_version)"
    fi
}

# Configure Factory
configure_factory() {
    log "Checking Factory configuration..."
    local config_dir="$HOME/.factory"
    local config_file="$config_dir/config.json"
    
    mkdir -p "$config_dir"
    
    # Check if config exists and has the correct API key
    if [[ -f "$config_file" ]]; then
        local current_api_key=$(jq -r '.api_key' "$config_file" 2>/dev/null || echo "")
        
        if [[ "$current_api_key" != "$FACTORY_API_KEY" ]]; then
            log "Updating Factory API key..."
            # Backup existing config
            cp "$config_file" "$config_file.bak"
            
            # Update API key while preserving other settings
            jq --arg api_key "$FACTORY_API_KEY" '.api_key = $api_key' "$config_file" > "$config_file.tmp" && mv "$config_file.tmp" "$config_file"
        else
            log "Factory API key already configured"
        fi
        
        # Check if custom model exists
        local has_glm_model=$(jq -r '.custom_models[]? | select(.model == "glm-4.6") | .model' "$config_file" 2>/dev/null || echo "")
        
        if [[ -z "$has_glm_model" ]]; then
            log "Adding GLM model to Factory configuration..."
            # Add GLM model to existing config
            jq --arg api_key "$ZAI_API_KEY" '.custom_models += [{
                "model_display_name": "GLM 4.6 Coding Plan",
                "model": "glm-4.6",
                "base_url": "https://api.z.ai/api/anthropic",
                "api_key": $api_key,
                "provider": "zai"
            }]' "$config_file" > "$config_file.tmp" && mv "$config_file.tmp" "$config_file"
        else
            log "GLM model already configured in Factory"
        fi
    else
        log "Creating new Factory configuration..."
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
    fi
}

# Setup workspace
setup_workspace() {
    log "Checking workspace setup..."
    
    if [[ ! -d ~/code ]]; then
        log "Creating workspace directory..."
        mkdir -p ~/code
    else
        log "Workspace directory already exists"
    fi
}

# Main execution
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
    
    log "Setup complete! Run 'source ~/.bashrc' to reload environment."
    log "Workspace ready at ~/code"
    log "Use 'gh-switch <num>' to switch GitHub accounts"
    log "Use 'gh-list' to see available accounts"
}

main "$@"
