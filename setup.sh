#!/usr/bin/env bash
set -euo pipefail

# --- Configuration & Globals ---
# Colors for cleaner output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
NC='\033[0m'

# Globals for step tracking and error handling
STEP_COUNTER=0
TOTAL_STEPS=8 # Total number of major steps in main()
CURRENT_STEP_DESC=""
SCRIPT_COMPLETE=false

# --- Core Infrastructure: Logging & Error Handling ---

# Trap to catch any script exit, successful or not
# If the exit is an error, it reports the last running step.
cleanup() {
    # $? is the exit code of the last command.
    if [[ $? -ne 0 && "$SCRIPT_COMPLETE" == false ]]; then
        error "Script failed on Step $STEP_COUNTER/$TOTAL_STEPS: $CURRENT_STEP_DESC"
        echo -e "${RED}Please check the output above for the specific error message.${NC}"
    fi
}
trap cleanup EXIT

# Primary log function
log() { echo -e "${GREEN}[$(date +'%H:%M:%S')]${NC} $*"; }
warn() { echo -e "${YELLOW}[WARN]${NC} $*"; }
error() { echo -e "${RED}[ERROR]${NC} $*"; exit 1; }

# Wrapper to run functions as formal, numbered steps
run_step() {
    STEP_COUNTER=$((STEP_COUNTER + 1))
    local func_name=$1
    CURRENT_STEP_DESC=$2
    
    echo -e "\n${CYAN}--- Step $STEP_COUNTER/$TOTAL_STEPS: $CURRENT_STEP_DESC ---${NC}"
    # Execute the function passed as an argument
    "$func_name"
    log "✓ Step $STEP_COUNTER/$TOTAL_STEPS: $CURRENT_STEP_DESC complete."
}


# --- Script Initialization ---
init() {
    log "Initializing setup..."
    # Determine if running as root and identify the real user
    if [[ $EUID -eq 0 ]]; then
        log "Running with sudo. System-wide changes will be applied."
        SYSTEM_INSTALL=true
        # Ensure SUDO_USER is set; otherwise, the script can't target the user's home dir.
        REAL_USER=${SUDO_USER:?"Script must be run with 'sudo', not directly as the root user."}
        REAL_HOME=$(getent passwd "$REAL_USER" | cut -d: -f6)
    else
        log "Running as user '$USER'. System package installation will be skipped."
        SYSTEM_INSTALL=false
        REAL_USER=$USER
        REAL_HOME=$HOME
    fi

    # Define Bun's location and update PATH for the *current script execution*
    # This is critical for subsequent commands to find executables installed in this script.
    BUN_INSTALL="$REAL_HOME/.bun"
    export PATH="$BUN_INSTALL/bin:$REAL_HOME/.local/bin:$PATH"
}


# --- Setup Functions ---

# Check for required environment variables from the .env file
check_env() {
    local required=("GITHUB_TOKEN" "FACTORY_API_KEY" "ZAI_API_KEY" "GIT_USER_NAME" "GIT_USER_EMAIL")
    for var in "${required[@]}"; do
        [[ -z "${!var:-}" ]] && error "$var is required. Set it in .env or export before running."
    done

    if [[ -n "${GITHUB_TOKENS:-}" ]]; then
        IFS=',' read -ra TOKENS <<< "$GITHUB_TOKENS"
        log "Found ${#TOKENS[@]} additional GitHub tokens."
    fi
}

# Install or verify system packages (requires root)
install_packages() {
    if [[ "$SYSTEM_INSTALL" != true ]]; then
        log "Not running as root, skipping system package installation."
        return
    fi

    export DEBIAN_FRONTEND=noninteractive
    log "Updating package lists..."
    apt-get update -qq

    local packages=("curl" "unzip" "htop" "tmux" "nodejs" "git" "jq")
    for package in "${packages[@]}"; do
        if ! dpkg -l | grep -q "^ii  $package "; then
            log "Installing $package..."
            apt-get install -y "$package"
        else
            log "$package is already installed."
        fi
    done
}

# Install Bun JS runtime for the correct user
install_bun() {
    local install_logic='
        set -e # <-- Ensure subshell exits on error
        log "Checking Bun installation for user $REAL_USER..."
        if ! command -v bun &> /dev/null; then
            log "Installing Bun..."
            curl -fsSL https://bun.sh/install | bash
            
            # Add to shell profile for *future* sessions
            if ! grep -q "BUN_INSTALL" "$REAL_HOME/.bashrc"; then
                echo "" >> "$REAL_HOME/.bashrc"
                echo "# Bun JS Runtime" >> "$REAL_HOME/.bashrc"
                echo "export BUN_INSTALL=\"\$HOME/.bun\"" >> "$REAL_HOME/.bashrc"
                echo "export PATH=\"\$BUN_INSTALL/bin:\$PATH\"" >> "$REAL_HOME/.bashrc"
                log "Added bun to .bashrc"
            fi
        else
            log "Bun is already installed (version: $(bun --version))"
        fi
    '
    sudo -u "$REAL_USER" bash -c "$(declare -f log); export HOME=\"$REAL_HOME\" PATH=\"$PATH\" REAL_USER=\"$REAL_USER\" REAL_HOME=\"$REAL_HOME\"; $install_logic"
}

# Install Claude Code CLI globally using Bun
install_claude() {
    local install_logic='
        set -e # <-- Ensure subshell exits on error
        log "Checking claude-code installation..."
        if ! bun pm ls -g | grep -q "@anthropic-ai/claude-code"; then
            log "Installing @anthropic-ai/claude-code..."
            bun install -g @anthropic-ai/claude-code
        else
            log "claude-code is already installed."
        fi
    '
    sudo -u "$REAL_USER" bash -c "$(declare -f log); export HOME=\"$REAL_HOME\" PATH=\"$PATH\"; $install_logic"
}

# Configure Git with user details from env vars
setup_git() {
    local setup_logic='
        set -e # <-- Ensure subshell exits on error
        log "Configuring Git for user $GIT_USER_NAME..."
        git config --global user.name "$GIT_USER_NAME"
        git config --global user.email "$GIT_USER_EMAIL"
        git config --global init.defaultBranch main
        git config --global pull.rebase false
    '
    sudo -u "$REAL_USER" bash -c "$(declare -f log); export HOME=\"$REAL_HOME\" GIT_USER_NAME=\"$GIT_USER_NAME\" GIT_USER_EMAIL=\"$GIT_USER_EMAIL\"; $setup_logic"
}

# Install and configure GitHub CLI
setup_gh() {
    # Install the 'gh' package if needed (requires root)
    if [[ "$SYSTEM_INSTALL" == true ]]; then
        if ! command -v gh &> /dev/null; then
            log "Installing GitHub CLI..."
            (
                export DEBIAN_FRONTEND=noninteractive
                curl -fsSL https://cli.github.com/packages/githubcli-archive-keyring.gpg | dd of=/usr/share/keyrings/githubcli-archive-keyring.gpg
                chmod 644 /usr/share/keyrings/githubcli-archive-keyring.gpg
                echo "deb [arch=$(dpkg --print-architecture) signed-by=/usr/share/keyrings/githubcli-archive-keyring.gpg] https://cli.github.com/packages stable main" > /etc/apt/sources.list.d/github-cli.list
                apt-get update -qq
                apt-get install -y gh
            ) || error "Failed to install GitHub CLI"
        else
            log "GitHub CLI is already installed."
        fi
    fi

    # Configure GH auth and add helpers for the real user
    local configure_logic='
        set -e # <-- Ensure subshell exits on error
        log "Configuring GitHub CLI for user $REAL_USER..."
        
        # Authenticate with primary token
        echo "$GITHUB_TOKEN" | gh auth login --with-token --hostname github.com
        gh auth setup-git
        gh config set git_protocol https
        log "GitHub CLI authenticated with primary token."

        # Define the functions to be added to .bashrc. Using a non-expanding heredoc.
        local BASHRC_FUNCTIONS
        read -r -d "" BASHRC_FUNCTIONS << "EOF"
# GitHub account switcher
gh-switch() {
    local account_num=${1:-1}
    if [[ $account_num -eq 1 ]]; then
        [[ -z "${GITHUB_TOKEN:-}" ]] && { echo "Error: GITHUB_TOKEN is not set." >&2; return 1; }
        echo "$GITHUB_TOKEN" | gh auth login --with-token --hostname github.com
        echo "Switched to primary GitHub account."
    elif [[ -f "$HOME/.config/gh/tokens/token_$account_num" ]]; then
        token=$(cat "$HOME/.config/gh/tokens/token_$account_num")
        echo "$token" | gh auth login --with-token --hostname github.com
        echo "Switched to GitHub account #$account_num."
    else
        echo "Token for account #$account_num not found." >&2; return 1;
    fi
}

gh-list() {
    echo "Available GitHub accounts:"
    echo "1: Primary (from GITHUB_TOKEN)"
    for token_file in "$HOME"/.config/gh/tokens/token_*; do
        if [[ -f "$token_file" ]]; then
            num=$(basename "$token_file" | cut -d"_" -f2)
            echo "$num: Additional token"
        fi
    done | sort -n
}
EOF

        # Store additional tokens if they exist
        if [[ -n "${GITHUB_TOKENS:-}" ]]; then
            mkdir -p "$REAL_HOME/.config/gh/tokens"
            IFS="," read -ra TOKENS <<< "$GITHUB_TOKENS"
            for i in "${!TOKENS[@]}"; do
                token_file="$REAL_HOME/.config/gh/tokens/token_$((i+2))"
                echo "${TOKENS[$i]}" > "$token_file"
                chmod 600 "$token_file"
                log "Stored additional GitHub token for account #$((i+2))"
            done
        fi

        # Add helper functions to .bashrc if not already present
        if ! grep -q "# GitHub account switcher" "$REAL_HOME/.bashrc"; then
            echo "" >> "$REAL_HOME/.bashrc"
            # Using printf to safely add the functions block
            printf "%s\n" "$BASHRC_FUNCTIONS" >> "$REAL_HOME/.bashrc"
            log "Added GitHub account switcher functions to .bashrc."
        else
            log "GitHub switcher functions already in .bashrc."
        fi
    '
    sudo -u "$REAL_USER" bash -c "$(declare -f log); export HOME=\"$REAL_HOME\" GITHUB_TOKEN=\"$GITHUB_TOKEN\" GITHUB_TOKENS=\"$GITHUB_TOKENS\" REAL_HOME=\"$REAL_HOME\"; $configure_logic"
}

# Install and configure Factory CLI
install_factory() {
    local install_logic='
        set -e # <-- Ensure subshell exits on error
        log "Checking Factory CLI..."
        if ! command -v factory &> /dev/null; then
            log "Installing Factory CLI..."
            curl -fsSL https://app.factory.ai/cli | sh
            # Ensure .local/bin is in the PATH for future sessions
            if ! grep -q ".local/bin" "$REAL_HOME/.bashrc"; then
                echo "" >> "$REAL_HOME/.bashrc"
                echo "# Add local binaries to PATH for Factory CLI" >> "$REAL_HOME/.bashrc"
                echo "export PATH=\"\$HOME/.local/bin:\$PATH\"" >> "$REAL_HOME/.bashrc"
            fi
        else
            log "Factory CLI is already installed."
        fi
    '
    sudo -u "$REAL_USER" bash -c "$(declare -f log); export HOME=\"$REAL_HOME\" PATH=\"$PATH\" REAL_HOME=\"$REAL_HOME\"; $install_logic"
}

configure_factory() {
    local configure_logic='
        set -e # <-- Ensure subshell exits on error
        log "Configuring Factory CLI..."
        local config_dir="$REAL_HOME/.factory"
        local config_file="$config_dir/config.json"
        mkdir -p "$config_dir"

        # Using jq to build the JSON configuration cleanly
        jq -n \
          --arg factory_api_key "$FACTORY_API_KEY" \
          --arg zai_api_key "$ZAI_API_KEY" \
          "{
            api_key: \$factory_api_key,
            custom_models: [
              {
                model_display_name: \"GLM 4.6 Coding Plan\",
                model: \"glm-4.6\",
                base_url: \"https://api.z.ai/api/anthropic\",
                api_key: \$zai_api_key,
                provider: \"zai\"
              }
            ]
          }" > "$config_file"
          
        log "Factory config file created/updated at $config_file."
    '
    sudo -u "$REAL_USER" bash -c "$(declare -f log); export HOME=\"$REAL_HOME\" FACTORY_API_KEY=\"$FACTORY_API_KEY\" ZAI_API_KEY=\"$ZAI_API_KEY\" REAL_HOME=\"$REAL_HOME\"; $configure_logic"
}

# Create a standard workspace directory
setup_workspace() {
    local setup_logic='
        set -e # <-- Ensure subshell exits on error
        if [[ ! -d "$REAL_HOME/code" ]]; then
            mkdir -p "$REAL_HOME/code"
            log "Created ~/code directory."
        else
            log "~/code directory already exists."
        fi
    '
    sudo -u "$REAL_USER" bash -c "$(declare -f log); export REAL_HOME=\"$REAL_HOME\"; $setup_logic"
}


# --- Main Execution ---
main() {
    init
    
    run_step check_env "Checking environment variables"
    run_step install_packages "Installing system packages"
    run_step setup_git "Configuring Git"
    run_step install_bun "Installing Bun.js runtime"
    run_step install_claude "Installing Claude Code CLI"
    run_step setup_gh "Installing & Configuring GitHub CLI"
    run_step install_factory "Installing Factory CLI"
    run_step configure_factory "Configuring Factory CLI"
    run_step setup_workspace "Creating workspace directory"

    SCRIPT_COMPLETE=true # Signal that the script has finished successfully

    echo -e "\n${GREEN}=====================================${NC}"
    echo -e "${GREEN}  Dev Environment Setup Complete!  ${NC}"
    echo -e "${GREEN}=====================================${NC}"
    log "Run ${CYAN}'source ~/.bashrc'${NC} or start a new shell to apply all changes."
    log "Your workspace is ready at: ${CYAN}$REAL_HOME/code${NC}"
    log "Use ${CYAN}'gh-list'${NC} and ${CYAN}'gh-switch <num>'${NC} to manage GitHub accounts."
}

# Run the main function with all script arguments
main "$@"
