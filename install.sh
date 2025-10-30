#!/usr/bin/env bash
# This script installs and configures an Aztec testnet node.
# It handles system dependencies, Docker, the Aztec CLI, and node configuration.
set -Eeuo pipefail

# ==========================================
# UI & Utility Functions
# ==========================================
green(){ echo -e "\033[1;32m$*\033[0m"; }
yellow(){ echo -e "\033[1;33m$*\033[0m"; }
red(){ echo -e "\033[1;31m$*\033[0m" >&2; }

info() { echo -e "\033[1;32m[INFO] $1\033[0m"; }
warn() { echo -e "\033[1;33m[WARN] $1\033[0m"; }
error() {
    echo -e "\033[1;31m[ERROR] $1\033[0m" >&2
    exit 1
}

command_exists() {
    command -v "$1" &> /dev/null
}

# ==========================================
# Pre-flight Checks & Initial Setup
# ==========================================
info "Performing pre-flight checks..."

# Minimal prerequisites
REQ_PKGS=("curl" "sudo" "tee" "awk" "sed" "grep" "cat" "printf")
for p in "${REQ_PKGS[@]}"; do
    command_exists "$p" || { red "Required command '$p' not found. Please install it."; exit 1; }
done

# Check for sudo privileges
if ! sudo -v &>/dev/null; then
    error "This script requires sudo privileges to install packages."
fi

# Determine user and home directory correctly, even when run with sudo
USER_NAME=${SUDO_USER:-$(whoami)}
HOME_DIR=$(getent passwd "$USER_NAME" | cut -d: -f6)
AZTEC_HOME="$HOME_DIR"
AZTEC_BIN="$AZTEC_HOME/.aztec/bin"
ARCH=$(uname -m)

info "Running as user: $USER_NAME"
info "Using home directory: $HOME_DIR"

if [ "$ARCH" != "x86_64" ]; then
    warn "Non-x86_64 architecture detected ($ARCH). Some packages might require adjustments."
fi

# ==========================================
# Step 1: System Dependencies & Update
# ==========================================
green "[1/6] Updating system and installing dependencies..."

sudo apt-get update -y || error "Failed to update package lists."
sudo apt-get upgrade -y || warn "Failed to upgrade all packages, but continuing."

info "Installing essential build tools and common utilities..."
sudo apt-get install -y \
    git clang cmake build-essential openssl pkg-config libssl-dev \
    wget htop tmux jq make gcc tar ncdu protobuf-compiler \
    default-jdk openssh-server sed lz4 aria2 pv \
    python3 python3-pip python3-dev screen \
    nano automake autoconf unzip \
    ca-certificates curl gnupg lsb-release software-properties-common || error "Failed to install one or more essential packages."

sudo apt-get autoremove -y || warn "Autoremove failed, but continuing."

# ==========================================
# Step 2: Docker Installation
# ==========================================
green "[2/6] Setting up Docker..."

if ! command_exists docker; then
    info "Installing Docker Engine and Docker Compose plugin..."
    
    sudo install -m 0755 -d /etc/apt/keyrings || error "Failed to create /etc/apt/keyrings."
    curl -fsSL https://download.docker.com/linux/ubuntu/gpg | sudo gpg --dearmor -o /etc/apt/keyrings/docker.gpg || error "Failed to download/install Docker GPG key."
    sudo chmod a+r /etc/apt/keyrings/docker.gpg || error "Failed to set permissions for Docker GPG key."

    echo \
      "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.gpg] https://download.docker.com/linux/ubuntu \
      $(. /etc/os-release && echo "$VERSION_CODENAME") stable" | \
      sudo tee /etc/apt/sources.list.d/docker.list > /dev/null || error "Failed to add Docker repository."

    sudo apt-get update -y || error "Failed to update apt-get after adding Docker repo."
    sudo apt-get install -y docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin || error "Failed to install Docker packages."

    info "Adding user '$USER_NAME' to 'docker' group."
    sudo usermod -aG docker "$USER_NAME" || error "Failed to add user '$USER_NAME' to 'docker' group."
    info "Docker installed. You may need to log out and back in for group changes to take full effect."
else
    info "Docker is already installed: $(docker --version)"
    if ! (docker compose version &>/dev/null); then
        warn "Docker is installed, but the 'docker compose' plugin seems to be missing. Attempting to install."
        sudo apt-get install -y docker-compose-plugin || error "Failed to install docker-compose-plugin."
    fi
fi

# ==========================================
# Step 3: Install Aztec CLI
# ==========================================
green "[3/6] Installing Aztec CLI..."

# **FIX:** Download to the user's home directory instead of /tmp to avoid disk space
# or permission issues with the temporary directory.
INSTALLER_PATH="$HOME_DIR/aztec-install.sh"

curl -fsSL https://install.aztec.network -o "$INSTALLER_PATH" || error "Failed to download Aztec installer. Please check your disk space with 'df -h'."

# Automate the installer prompts: continue=y, add-to-PATH=n
# We run the installer as the original user, not as root.
printf 'y\nn\n' | sudo -u "$USER_NAME" bash "$INSTALLER_PATH"

# Clean up the installer script
rm -f "$INSTALLER_PATH"

# Add PATH to .bashrc (if not already there) and export for the current session
if ! grep -q "$AZTEC_BIN" "$HOME_DIR/.bashrc" 2>/dev/null; then
    info "Adding Aztec to PATH in $HOME_DIR/.bashrc"
    echo "export PATH=\$PATH:$AZTEC_BIN" >> "$HOME_DIR/.bashrc"
fi
export PATH="$PATH:$AZTEC_BIN"

# Upgrade to the specific required version
if [ -x "$AZTEC_BIN/aztec-up" ]; then
    info "Upgrading Aztec CLI to version 2.0.4..."
    "$AZTEC_BIN/aztec-up" -v 2.0.4
else
    error "aztec-up command not found in $AZTEC_BIN after installation."
fi

# ==========================================
# Step 4: User Configuration
# ==========================================
green "[4/6] Please provide your configuration..."
read -rp "ETHEREUM_RPC_URL: " ETHEREUM_RPC_URL
read -rp "CONSENSUS_BEACON_URL: " CONSENSUS_BEACON_URL
read -rp "VALIDATOR_PRIVATE_KEYS (comma-separated): " VALIDATOR_PRIVATE_KEYS
read -rp "COINBASE (Your Wallet Address): " COINBASE

# Validate that inputs are not empty
for varname in ETHEREUM_RPC_URL CONSENSUS_BEACON_URL VALIDATOR_PRIVATE_KEYS COINBASE; do
    if [ -z "${!varname}" ]; then
        error "$varname must not be empty."
    fi
done

# Auto-detect Public IP
info "Detecting public IP address for P2P_IP..."
detect_public_ip() {
    curl -fsS --max-time 8 https://api.ipify.org || \
    curl -fsS --max-time 8 https://ifconfig.me || \
    hostname -I 2>/dev/null | awk '{print $1}'
}
P2P_IP=$(detect_public_ip)

if [ -z "$P2P_IP" ]; then
    yellow "Auto-detection of public IP failed. Please enter it manually."
    read -rp "P2P_IP: " P2P_IP
    [ -z "$P2P_IP" ] && { error "P2P_IP cannot be empty."; }
else
    green "Public IP detected: $P2P_IP"
fi

# ==========================================
# Step 5: Create Docker Config Files
# ==========================================
green "[5/6] Creating directory and config files..."
AZTEC_DIR="$HOME_DIR/aztec"
mkdir -p "$AZTEC_DIR"
cd "$AZTEC_DIR"

# Backup existing files
[ -f .env ] && { info "Backing up existing .env file..."; mv .env ".env.bak.$(date +%s)"; }
[ -f docker-compose.yml ] && { info "Backing up existing docker-compose.yml..."; mv docker-compose.yml "docker-compose.yml.bak.$(date +%s)"; }

# Write .env file
info "Writing configuration to $AZTEC_DIR/.env"
cat > .env <<EOF
ETHEREUM_RPC_URL=${ETHEREUM_RPC_URL}
CONSENSUS_BEACON_URL=${CONSENSUS_BEACON_URL}
VALIDATOR_PRIVATE_KEYS=${VALIDATOR_PRIVATE_KEYS}
COINBASE=${COINBASE}
P2P_IP=${P2P_IP}
GOVERNANCE_PAYLOAD=0xDCd9DdeAbEF70108cE02576df1eB333c4244C666
AZTEC_ADMIN_PORT=8880
EOF

# Write docker-compose.yml file
info "Writing configuration to $AZTEC_DIR/docker-compose.yml"
cat > docker-compose.yml <<YAML
services:
  aztec-node:
    container_name: aztec-sequencer
    image: aztecprotocol/aztec:2.0.4
    restart: unless-stopped
    environment:
      ETHEREUM_HOSTS: \${ETHEREUM_RPC_URL}
      L1_CONSENSUS_HOST_URLS: \${CONSENSUS_BEACON_URL}
      DATA_DIRECTORY: /data
      VALIDATOR_PRIVATE_KEYS: \${VALIDATOR_PRIVATE_KEYS}
      COINBASE: \${COINBASE}
      P2P_IP: \${P2P_IP}
      GOVERNANCE_PAYLOAD: \${GOVERNANCE_PAYLOAD}
      AZTEC_ADMIN_PORT: \${AZTEC_ADMIN_PORT}
      LOG_LEVEL: info
    entrypoint: >
      sh -c "node --no-warnings /usr/src/yarn-project/aztec/dest/bin/index.js start
      --network testnet
      --node
      --archiver
      --sequencer
      --snapshots-url https://snapshots.aztec.graphops.xyz/files
      --port 8080"
    ports:
      - "40400:40400/tcp"
      - "40400:40400/udp"
      - "8080:8080"
      - "8880:8880"
    volumes:
      - "${HOME_DIR}/.aztec/testnet/data/:/data"
YAML

# Ensure the owner of the config files is the original user
sudo chown -R "$USER_NAME:$USER_NAME" "$AZTEC_DIR"

# ==========================================
# Step 6: Start the Aztec Node
# ==========================================
green "[6/6] Starting the Aztec node via Docker Compose..."

# Detect which compose command to use
if command_exists docker && docker compose version &>/dev/null; then
    COMPOSE_CMD="docker compose"
elif command_exists docker-compose; then
    COMPOSE_CMD="docker-compose"
else
    error "Docker Compose not found. Please ensure it's installed correctly."
fi

sudo $COMPOSE_CMD up -d

green "✅ Done! Your Aztec node is starting in the background."
echo
echo "================ SUMMARY ================"
echo "Working directory: $AZTEC_DIR"
echo "Public IP Address: $P2P_IP"
echo
echo "To check the logs of your node, run:"
yellow "  docker logs -f aztec-sequencer"
echo
echo "To stop your node, run:"
yellow "  cd $AZTEC_DIR && docker compose down"
echo "========================================"
