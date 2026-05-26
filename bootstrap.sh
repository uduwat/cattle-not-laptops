#!/bin/bash
set -e

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# Helper functions
info() {
  echo -e "${BLUE}ℹ ${NC}$1"
}

success() {
  echo -e "${GREEN}✓${NC} $1"
}

warn() {
  echo -e "${YELLOW}⚠ ${NC}$1"
}

error() {
  echo -e "${RED}✗ ${NC}$1"
}

# Header
echo ""
echo -e "${GREEN}╔═══════════════════════════════════════════╗${NC}"
echo -e "${GREEN}║  Cattle Not Laptops - Bootstrap Script   ║${NC}"
echo -e "${GREEN}║  Automated System Provisioning with      ║${NC}"
echo -e "${GREEN}║  Ansible & Chezmoi                       ║${NC}"
echo -e "${GREEN}╚═══════════════════════════════════════════╝${NC}"
echo ""

# ===== Step 1: Check OS =====
info "Checking system compatibility..."
if ! grep -qi "RHEL\|CentOS\|Fedora\|AlmaLinux\|Rocky" /etc/os-release 2>/dev/null; then
  error "This script requires RHEL/CentOS/Fedora/AlmaLinux/Rocky Linux"
  echo "Detected OS:"
  cat /etc/os-release | grep PRETTY_NAME
  exit 1
fi
success "OS check passed"
echo ""

# ===== Step 2: Check/install Ansible and git =====
info "Checking for required tools..."

if ! command -v ansible-pull &> /dev/null; then
  warn "ansible-pull not found; installing Ansible..."
  if ! command -v sudo &> /dev/null; then
    error "sudo not found. This script requires sudo access"
    exit 1
  fi
  sudo dnf install -y ansible-core git
  success "Ansible installed"
else
  success "Ansible already installed"
fi

if ! command -v git &> /dev/null; then
  warn "git not found; installing..."
  sudo dnf install -y git
  success "git installed"
else
  success "git already installed"
fi
echo ""

# ===== Step 3: Prompt for principaluser =====
info "Configuration Setup"
echo ""
read -p "$(echo -e ${BLUE}'Principal user'${NC} '[default: '$USER']: ')" principaluser
principaluser=${principaluser:-$USER}

if ! id "$principaluser" &>/dev/null; then
  warn "User '$principaluser' does not exist on this system"
  read -p "Create user '$principaluser'? (y/n) [default: y]: " create_user
  if [ "$create_user" != "n" ]; then
    info "User creation is not yet automated. Please create manually:"
    echo "  sudo useradd -m -s /bin/bash $principaluser"
    exit 1
  else
    error "Cannot proceed without existing user"
    exit 1
  fi
fi

success "Using principaluser: $principaluser"
echo ""

# ===== Step 4: Prompt for dotfiles_repo =====
info "Dotfiles Configuration"

# Check environment variable first
if [ -n "$DOTFILES_REPO" ]; then
  dotfiles_repo="$DOTFILES_REPO"
  success "Using DOTFILES_REPO from environment: $dotfiles_repo"
else
  echo ""
  read -p "$(echo -e ${BLUE}'Dotfiles repo URL'${NC} '(press Enter to skip): ')" dotfiles_repo
  
  if [ -z "$dotfiles_repo" ]; then
    warn "Skipping dotfiles (will use default shell/editor config)"
    dotfiles_repo=""
  else
    success "Using dotfiles repo: $dotfiles_repo"
  fi
fi
echo ""

# ===== Step 5: Determine authentication method =====
if [ -n "$dotfiles_repo" ]; then
  info "Detecting authentication method..."
  echo ""
  
  ssh_key_found=0
  if [ -f ~/.ssh/id_ed25519 ]; then
    success "Found SSH key: ~/.ssh/id_ed25519"
    ssh_key_found=1
  elif [ -f ~/.ssh/id_rsa ]; then
    success "Found SSH key: ~/.ssh/id_rsa"
    ssh_key_found=1
  else
    warn "No SSH keys found (~/.ssh/id_rsa or ~/.ssh/id_ed25519)"
  fi
  echo ""
  
  # If HTTPS URL and SSH key exists, offer conversion
  if [ $ssh_key_found -eq 1 ] && [[ "$dotfiles_repo" == https://* ]]; then
    echo "Your dotfiles repo is HTTPS, but SSH keys are available."
    read -p "$(echo -e ${BLUE}'Convert to SSH URL?'${NC} '(y/n) [default: y]: ')" convert_ssh
    convert_ssh=${convert_ssh:-y}
    
    if [ "$convert_ssh" = "y" ]; then
      # Convert https://github.com/user/repo.git -> git@github.com:user/repo.git
      dotfiles_repo=$(echo "$dotfiles_repo" | sed 's|https://github.com/|git@github.com:|')
      success "Converted to SSH: $dotfiles_repo"
    fi
  fi
  
  # If no SSH key and still HTTPS with embedded PAT, keep it
  # If no SSH key and HTTPS without auth, prompt for PAT
  if [ $ssh_key_found -eq 0 ] && [[ "$dotfiles_repo" == https://github.com/* ]] && [[ "$dotfiles_repo" != *"@"* ]]; then
    echo ""
    warn "No SSH keys detected. For private repos, provide a GitHub Personal Access Token."
    echo "To create a PAT:"
    echo "  1. Visit: https://github.com/settings/tokens"
    echo "  2. Create token with 'repo' scope"
    echo "  3. Enter PAT below (will be embedded in URL)"
    echo ""
    read -sp "$(echo -e ${BLUE}'GitHub PAT (leave empty for public repos)'${NC}': ')" pat
    echo ""
    
    if [ -n "$pat" ]; then
      # Insert PAT into URL: https://github.com/user/repo.git -> https://PAT@github.com/user/repo.git
      dotfiles_repo="https://${pat}@${dotfiles_repo#https://}"
      success "PAT configured"
    fi
  fi
  echo ""
fi

# ===== Step 6: Optional - Set up systemd timer =====
info "Scheduled Provisioning (Optional)"
echo ""
read -p "$(echo -e ${BLUE}'Enable daily scheduled runs?'${NC} '(y/n) [default: n]: ')" enable_timer
enable_timer=${enable_timer:-n}

if [ "$enable_timer" = "y" ]; then
  # Strip PAT from dotfiles_repo for the systemd unit (security)
  dotfiles_repo_safe=$(echo "$dotfiles_repo" | sed 's|https://[^@]*@|https://|')
  if [ "$dotfiles_repo_safe" != "$dotfiles_repo" ]; then
    warn "dotfiles_repo contains a PAT; stripped for systemd unit"
    warn "Scheduled runs will need SSH key or credential helper configured"
  fi

  mkdir -p ~/.config/systemd/user

  # Create service file
  cat > ~/.config/systemd/user/ansible-pull.service <<EOF
[Unit]
Description=Cattle Not Laptops - Automated Provisioning
After=network-online.target
Wants=network-online.target

[Service]
Type=oneshot
ExecStart=/usr/bin/ansible-pull \\
  -U https://github.com/uduwat/cattle-not-laptops.git \\
  -e principaluser=${principaluser} \\
  -e dotfiles_repo=${dotfiles_repo_safe} \\
  local.yml
StandardOutput=journal
StandardError=journal

[Install]
WantedBy=multi-user.target
EOF

  # Create timer file
  cat > ~/.config/systemd/user/ansible-pull.timer <<EOF
[Unit]
Description=Cattle Not Laptops - Daily Scheduled Run

[Timer]
OnBootSec=5min
OnUnitActiveSec=1d
Persistent=true

[Install]
WantedBy=timers.target
EOF

  chmod 644 ~/.config/systemd/user/ansible-pull.{service,timer}
  systemctl --user daemon-reload
  systemctl --user enable ansible-pull.timer
  systemctl --user start ansible-pull.timer
  success "Systemd timer installed and started"
  info "To check timer status: systemctl --user status ansible-pull.timer"
  info "To view logs: journalctl --user -u ansible-pull.service"
else
  warn "Skipping systemd timer setup"
fi
echo ""

# ===== Step 7: Run ansible-pull =====
echo -e "${GREEN}════════════════════════════════════════════${NC}"
info "Running ansible-pull..."
echo -e "${GREEN}════════════════════════════════════════════${NC}"
echo ""

# Build ansible-pull command
ANSIBLE_PULL_CMD=(
  "ansible-pull"
  "-U" "https://github.com/uduwat/cattle-not-laptops.git"
  "-e" "principaluser=${principaluser}"
  "-e" "dotfiles_repo=${dotfiles_repo}"
  "--accept-host-key"
  "-v"
  "local.yml"
)

# Run with sudo if not already running as root/via sudo
if [ "$EUID" -ne 0 ] && ! sudo -n true 2>/dev/null; then
  warn "ansible-pull requires sudo; you may be prompted for password"
fi

if sudo "${ANSIBLE_PULL_CMD[@]}"; then
  echo ""
  echo -e "${GREEN}════════════════════════════════════════════${NC}"
  success "Bootstrap complete!"
  echo -e "${GREEN}════════════════════════════════════════════${NC}"
  echo ""
  echo "Your system has been provisioned with:"
  echo "  • Common tools (openssl, git, etc.)"
  echo "  • Dotfiles management (chezmoi)"
  echo "  • Shell enhancements (fish, plugins, tools)"
  echo "  • Development utilities"
  echo "  • Code editors and tools"
  echo "  • Linters and syntax checkers"
  echo "  • Cloud utilities (GCP CLI, kubectl)"
  echo "  • File managers"
  echo "  • Git CLI tools"
  echo "  • Secret manager (keepassxc)"
  echo ""
  if [ "$enable_timer" = "y" ]; then
    echo "Automatic daily runs are enabled."
    echo "You can view logs with: journalctl --user -u ansible-pull.service"
  fi
  echo ""
  echo "For troubleshooting or more info, see: https://github.com/uduwat/cattle-not-laptops"
else
  echo ""
  error "ansible-pull failed. Please check the output above."
  echo ""
  echo "Common issues:"
  echo "  • Private dotfiles repo: Verify SSH key or PAT"
  echo "  • Network error: Check your internet connection"
  echo "  • Permission denied: Verify principaluser and sudo access"
  echo ""
  echo "For help, see SETUP.md in the repository."
  exit 1
fi
