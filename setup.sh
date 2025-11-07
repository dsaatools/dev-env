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
    local required=("GITHUB_TOKEN" "FACTORY_API_KEY" "ZAI_API_KEY")
    for var in "${required[@]}"; do
        [[ -z "${!var:-}" ]] && error "$var is required. Set it in .env or export before running."
    done
}

# Install system packages
install_packages() {
    log "Installing system packages..."
    export DEBIAN_FRONTEND=noninteractive
    apt-get update -qq
    apt-get install -y curl unzip htop tmux nodejs git
}

# Install bun
install_bun() {
    log "Installing bun..."
    if ! command -v bun &> /dev/null; then
        curl -fsSL https://bun.sh/install | bash
        export BUN_INSTALL="$HOME/.bun"
        export PATH="$BUN_INSTALL/bin:$PATH"
        echo 'export BUN_INSTALL="$HOME/.bun"' >> ~/.bashrc
        echo 'export PATH="$BUN_INSTALL/bin:$PATH"' >> ~/.bashrc
    else
        log "bun already installed"
    fi
}

# Install claude-code
install_claude() {
    log "Installing claude-code..."
    bun install -g @anthropic-ai/claude-code
}

# Setup GitHub CLI
setup_gh() {
    log "Setting up GitHub CLI..."
    if ! command -v gh &> /dev/null; then
        curl -fsSL https://cli.github.com/packages/githubcli-archive-keyring.gpg | dd of=/usr/share/keyrings/githubcli-archive-keyring.gpg
        echo "deb [arch=$(dpkg --print-architecture) signed-by=/usr/share/keyrings/githubcli-archive-keyring.gpg] https://cli.github.com/packages stable main" | tee /etc/apt/sources.list.d/github-cli.list > /dev/null
        apt-get update -qq
        apt-get install -y gh
    fi
    
    # Non-interactive auth
    echo "$GITHUB_TOKEN" | gh auth login --with-token
    gh config set git_protocol https
}

# Install Factory CLI
install_factory() {
    log "Installing Factory CLI..."
    curl -fsSL https://app.factory.ai/cli | sh
    echo 'export PATH="$HOME/.local/bin:$PATH"' >> ~/.bashrc
    export PATH="$HOME/.local/bin:$PATH"
}

# Configure Factory
configure_factory() {
    log "Configuring Factory CLI..."
    mkdir -p ~/.factory
    
    cat > ~/.factory/config.json << EOF
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

# Setup workspace
setup_workspace() {
    log "Setting up workspace..."
    mkdir -p ~/code
    cd ~/code
}

# Main execution
main() {
    log "Starting dev environment setup..."
    check_env
    install_packages
    install_bun
    install_claude
    setup_gh
    install_factory
    configure_factory
    setup_workspace
    
    log "Setup complete! Run 'source ~/.bashrc' to reload environment."
    log "Workspace ready at ~/code"
}

main "$@"
