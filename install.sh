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

INSTALLER_PATH="$HOME_DIR/aztec-install.sh"

curl -fsSL https://install.aztec.network -o "$INSTALLER_PATH" || error "Failed to download Aztec installer. Please check your disk space with 'df -h'."

# Automate the installer prompts: continue=y, add-to-PATH=n
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
    info "Upgrading Aztec CLI to version 2.1.2..."
    "$AZTEC_BIN/aztec-up" -v 2.1.2
else
    error "aztec-up command not found in $AZTEC_BIN after installation."
fi

# ==========================================
# Step 4: User Configuration
# ==========================================
green "[4/6] Please provide your configuration..."
read -rp "ETHEREUM_HOSTS (Ethereum RPC URL): " ETHEREUM_HOSTS
read -rp "L1_CONSENSUS_HOST_URLS (Consensus Beacon URL): " L1_CONSENSUS_HOST_URLS
read -rp "VALIDATOR_PRIVATE_KEY (Ethereum Private Key): " VALIDATOR_PRIVATE_KEY
read -rp "COINBASE (Your Wallet Address): " COINBASE
read -rp "BLS_PRIVATE_KEY: " BLS_PRIVATE_KEY

# Validate that inputs are not empty
for varname in ETHEREUM_HOSTS L1_CONSENSUS_HOST_URLS VALIDATOR_PRIVATE_KEY COINBASE BLS_PRIVATE_KEY; do
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
# Step 5: Create Directory Structure and Config Files
# ==========================================
green "[5/6] Creating directory structure and config files..."
AZTEC_DIR="$HOME_DIR/aztec"
mkdir -p "$AZTEC_DIR/data" "$AZTEC_DIR/keys"
cd "$AZTEC_DIR"

# Create keystore.json
info "Creating keystore.json in $AZTEC_DIR/keys/"
cat > "$AZTEC_DIR/keys/keystore.json" <<EOF
{
  "schemaVersion": 1,
  "validators": [
    {
      "attester": {
        "eth": "$VALIDATOR_PRIVATE_KEY",
        "bls": "$BLS_PRIVATE_KEY"
      },
      "feeRecipient": "0x0000000000000000000000000000000000000000000000000000000000000000",
      "coinbase": "$COINBASE"
    }
  ]
}
EOF

# Backup existing files
[ -f .env ] && { info "Backing up existing .env file..."; mv .env ".env.bak.$(date +%s)"; }
[ -f docker-compose.yml ] && { info "Backing up existing docker-compose.yml..."; mv docker-compose.yml "docker-compose.yml.bak.$(date +%s)"; }

# Write .env file
info "Writing configuration to $AZTEC_DIR/.env"
cat > .env <<EOF
DATA_DIRECTORY=./data
KEY_STORE_DIRECTORY=./keys
LOG_LEVEL=info
ETHEREUM_HOSTS=${ETHEREUM_HOSTS}
L1_CONSENSUS_HOST_URLS=${L1_CONSENSUS_HOST_URLS}
P2P_IP=${P2P_IP}
GOVERNANCE_PROPOSER_PAYLOAD_ADDRESS=0xDCd9DdeAbEF70108cE02576df1eB333c4244C666
P2P_PORT=40400
AZTEC_PORT=8080
AZTEC_ADMIN_PORT=8880
EOF

# Write docker-compose.yml file
info "Writing configuration to $AZTEC_DIR/docker-compose.yml"
cat > docker-compose.yml <<'YAML'
version: '3.8'

services:
  aztec-sequencer:
    image: "aztecprotocol/aztec:2.1.2"
    container_name: "aztec"
    ports:
      - "${AZTEC_PORT}:${AZTEC_PORT}"
      - "${AZTEC_ADMIN_PORT}:${AZTEC_ADMIN_PORT}"
      - "${P2P_PORT}:${P2P_PORT}"
      - "${P2P_PORT}:${P2P_PORT}/udp"
    volumes:
      - ${DATA_DIRECTORY}:/var/lib/data
      - ${KEY_STORE_DIRECTORY}:/var/lib/keystore
    environment:
      KEY_STORE_DIRECTORY: /var/lib/keystore
      DATA_DIRECTORY: /var/lib/data
      LOG_LEVEL: ${LOG_LEVEL}
      ETHEREUM_HOSTS: ${ETHEREUM_HOSTS}
      L1_CONSENSUS_HOST_URLS: ${L1_CONSENSUS_HOST_URLS}
      GOVERNANCE_PROPOSER_PAYLOAD_ADDRESS: ${GOVERNANCE_PROPOSER_PAYLOAD_ADDRESS}
      P2P_IP: ${P2P_IP}
      P2P_PORT: ${P2P_PORT}
      AZTEC_PORT: ${AZTEC_PORT}
      AZTEC_ADMIN_PORT: ${AZTEC_ADMIN_PORT}
    entrypoint: >
      node
      --no-warnings
      /usr/src/yarn-project/aztec/dest/bin/index.js
      start
      --node
      --archiver
      --sequencer
      --network testnet
    networks:
      - aztec
    restart: always

networks:
  aztec:
    name: aztec
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

cd "$AZTEC_DIR"
sudo $COMPOSE_CMD up -d

green "✅ Done! Your Aztec node is starting in the background."
echo
echo "================ SUMMARY ================"
echo "Working directory: $AZTEC_DIR"
echo "Public IP Address: $P2P_IP"
echo "Data directory: $AZTEC_DIR/data"
echo "Keys directory: $AZTEC_DIR/keys"
echo
echo "To check the logs of your node, run:"
yellow "  docker logs -f --tail 200 aztec"
echo
echo "To stop your node, run:"
yellow "  cd $AZTEC_DIR && docker compose down"
echo "========================================"
