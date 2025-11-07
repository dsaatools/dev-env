

# Dev Environment Setup Script

Automated Ubuntu development environment setup with modern tools. Idempotent, non-interactive, perfect for fresh VPS instances or CI/CD pipelines.

## Quick Start

```bash
# Create .env file
cat > .env << EOF
GITHUB_TOKEN=ghp_your_github_token
FACTORY_API_KEY=your_factory_api_key
ZAI_API_KEY=your_zai_api_key
GIT_USER_NAME="Your Name"
GIT_USER_EMAIL="your.email@example.com"
GITHUB_TOKENS=ghp_token2,ghp_token3  # Optional
EOF

# One-liner setup
curl -fsSL https://raw.githubusercontent.com/dsaatools/dev-env/main/setup.sh | bash
```

## What It Installs

- **System**: `curl`, `unzip`, `htop`, `tmux`, `nodejs`, `git`
- **Runtime**: `bun` (JavaScript runtime)
- **AI Tools**: `claude-code`, `Factory CLI` with custom GLM-4.6 model
- **DevOps**: `GitHub CLI` with multi-account support

## Environment Variables

| Variable | Required | Description |
|----------|----------|-------------|
| `GITHUB_TOKEN` | ✓ | Primary GitHub personal access token |
| `FACTORY_API_KEY` | ✓ | Factory AI API key |
| `ZAI_API_KEY` | ✓ | Z.ai API key for GLM-4.6 model |
| `GIT_USER_NAME` | ✓ | Git user.name |
| `GIT_USER_EMAIL` | ✓ | Git user.email |
| `GITHUB_TOKENS` | - | Comma-separated additional GitHub tokens |

## Features

### Idempotent Design
- Detects existing installations
- Only updates what changed
- Backs up configurations before modification
- Tracks state between runs

### Multi-Account GitHub
```bash
gh-switch 1    # Switch to primary account
gh-switch 2    # Switch to second account
gh-list        # List all available accounts
```

### Smart Configuration Updates
- Detects `.env` changes
- Updates only affected services
- Preserves existing settings

## Usage Examples

### Fresh VPS Setup
```bash
# On fresh Ubuntu server
curl -fsSL https://raw.githubusercontent.com/dsaatools/dev-env/main/setup.sh | bash
source ~/.bashrc
cd ~/code
```

### CI/CD Pipeline
```yaml
- name: Setup Dev Environment
  env:
    GITHUB_TOKEN: ${{ secrets.GITHUB_TOKEN }}
    FACTORY_API_KEY: ${{ secrets.FACTORY_API_KEY }}
    ZAI_API_KEY: ${{ secrets.ZAI_API_KEY }}
    GIT_USER_NAME: "CI Bot"
    GIT_USER_EMAIL: "ci@example.com"
  run: |
    curl -fsSL https://raw.githubusercontent.com/dsaatools/dev-env/main/setup.sh | bash
    source ~/.bashrc
```

### Updating Configuration
```bash
# Modify .env with new tokens/emails
# Re-run script - only changes will be applied
curl -fsSL https://raw.githubusercontent.com/dsaatools/dev-env/main/setup.sh | bash
```

## Directory Structure

```
~
├── .bun/                 # Bun installation
├── .factory/             # Factory CLI config
│   └── config.json       # AI model configurations
├── .config/gh/           # GitHub CLI
│   └── tokens/           # Additional account tokens
├── .local/bin/           # Local binaries (droid CLI)
├── .dev-env-state.json   # State tracking
├── .bashrc               # Updated with PATH and functions
└── code/                 # Workspace directory
```

## Security Notes

- Tokens stored with `600` permissions
- State file only tracks first 10 characters of tokens
- Backup files created with timestamps
- No tokens logged in plain text

## Troubleshooting

### Permission Denied
```bash
# Ensure sudo access or run as root
sudo su
curl -fsSL https://raw.githubusercontent.com/dsaatools/dev-env/main/setup.sh | bash
```

### GitHub Auth Issues
```bash
# Check current auth status
gh auth status

# Switch accounts
gh-switch 1
```

### Factory CLI Not Found
```bash
# Ensure PATH is updated
source ~/.bashrc

# Check installation
which droid
```

### State Reset
```bash
# Remove state file to force full reconfiguration
rm ~/.dev-env-state.json
```

## Minimum Requirements

- Ubuntu 20.04+ or compatible Debian-based distro
- `sudo` or root access
- Internet connection
- ~500MB disk space

## Development

```bash
# Test locally
./setup.sh

# Validate syntax
bash -n setup.sh

# Test with custom env
GITHUB_TOKEN=test FACTORY_API_KEY=test ZAI_API_KEY=test GIT_USER_NAME=test GIT_USER_EMAIL=test@test.com ./setup.sh
```

## License

MIT - Feel free to fork and modify for your needs.
