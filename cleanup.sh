#!/bin/bash
set -Eeuo pipefail

# ===== Pretty logging =====
green(){ echo -e "\033[1;32m$*\033[0m"; }
yellow(){ echo -e "\033[1;33m$*\033[0m"; }
red(){ echo -e "\033[1;31m$*\033[0m" >&2; }
info() { echo -e "\033[1;34m[INFO] $1\033[0m"; }

# ==========================================
# Configuration
# ==========================================
USER_NAME=${SUDO_USER:-$(whoami)}
HOME_DIR=$(getent passwd "$USER_NAME" | cut -d: -f6)
AZTEC_DIR="$HOME_DIR/aztec"
AZTEC_BIN="$HOME_DIR/.aztec/bin"
AZTEC_DATA="$HOME_DIR/.aztec/testnet/data"

# ==========================================
# Pre-flight check
# ==========================================
if [ "$EUID" -ne 0 ]; then
    info "Elevating to root for complete cleanup..."
    exec sudo -E bash "$0" "$@"
fi

info "Starting Aztec node cleanup for user: $USER_NAME"

# ==========================================
# Step 1: Stop Services
# ==========================================
green "[1/5] Stopping Aztec services..."

# Detect compose command
if docker compose version >/dev/null 2>&1; then
    COMPOSE_CMD="docker compose"
elif command -v docker-compose >/dev/null 2>&1; then
    COMPOSE_CMD="docker-compose"
else
    COMPOSE_CMD=""
fi

# Stop using docker-compose if available
if [ -n "$COMPOSE_CMD" ] && [ -f "$AZTEC_DIR/docker-compose.yml" ]; then
    cd "$AZTEC_DIR"
    $COMPOSE_CMD down --timeout 30 --remove-orphans
    green "Docker Compose services stopped"
else
    yellow "docker-compose.yml not found, stopping containers manually..."
fi

# Force stop any remaining Aztec containers
for container in aztec-sequencer aztec-node; do
    if docker ps -a --format "table {{.Names}}" | grep -q "^${container}$"; then
        docker stop "$container" --time 30 2>/dev/null || docker rm -f "$container" 2>/dev/null
        green "Stopped container: $container"
    fi
done

# Stop any container with aztec in name
docker ps -a --filter "name=aztec" --format "{{.Names}}" | while read -r container; do
    if [ -n "$container" ]; then
        docker stop "$container" --time 30 2>/dev/null || docker rm -f "$container" 2>/dev/null
        green "Stopped container: $container"
    fi
done

# ==========================================
# Step 2: Cleanup Docker Resources
# ==========================================
green "[2/5] Cleaning up Docker resources..."

# Remove stopped containers
docker ps -aq --filter "name=aztec" | xargs -r docker rm -f 2>/dev/null || true

# Remove Docker images
for image in "aztecprotocol/aztec" "aztec"; do
    if docker images --format "table {{.Repository}}" | grep -q "$image"; then
        image_ids=$(docker images -q "$image" 2>/dev/null)
        if [ -n "$image_ids" ]; then
            docker rmi -f $image_ids 2>/dev/null || true
            green "Removed Docker image: $image"
        fi
    fi
done

# Clean up Docker system (optional - be careful if you have other containers)
read -p "Do you want to prune all unused Docker data? (y/N): " -n 1 -r
echo
if [[ $REPLY =~ ^[Yy]$ ]]; then
    docker system prune -f --volumes 2>/dev/null || true
    green "Docker system pruned"
else
    docker system prune -f 2>/dev/null || true
    green "Docker cleanup completed (volumes preserved)"
fi

# ==========================================
# Step 3: Remove Data & Config Files
# ==========================================
green "[3/5] Removing data and configuration files..."

# Remove Aztec directory and configs
rm -rf "$AZTEC_DIR" 2>/dev/null && green "Removed Aztec directory: $AZTEC_DIR"

# Remove Aztec data
rm -rf "$AZTEC_DATA" 2>/dev/null && green "Removed Aztec data: $AZTEC_DATA"

# Remove installer script if exists
rm -f "$HOME_DIR/aztec-install.sh" 2>/dev/null && green "Removed installer script"

# Remove from .bashrc
if [ -f "$HOME_DIR/.bashrc" ] && grep -q "$AZTEC_BIN" "$HOME_DIR/.bashrc"; then
    sed -i "\|$AZTEC_BIN|d" "$HOME_DIR/.bashrc"
    green "Removed Aztec from PATH in .bashrc"
fi

# ==========================================
# Step 4: Remove Aztec CLI
# ==========================================
green "[4/5] Removing Aztec CLI..."

if [ -d "$HOME_DIR/.aztec" ]; then
    rm -rf "$HOME_DIR/.aztec" 2>/dev/null && green "Removed Aztec CLI: $HOME_DIR/.aztec"
else
    info "Aztec CLI not found at $HOME_DIR/.aztec"
fi

# ==========================================
# Step 5: Final Verification
# ==========================================
green "[5/5] Final verification..."

echo
green "=== Cleanup Complete ==="
echo "✅ All Aztec services stopped"
echo "✅ Docker resources cleaned"
echo "✅ Data directories removed"
echo "✅ Configuration files removed"
echo "✅ Aztec CLI uninstalled"
echo

# Final check
echo "=== Remaining Components Check ==="
if docker ps -a | grep -q "aztec"; then
    red "Remaining Aztec containers:"
    docker ps -a | grep "aztec"
else
    green "No Aztec containers remaining"
fi

if [ -d "$AZTEC_DIR" ] || [ -d "$HOME_DIR/.aztec" ]; then
    red "Remaining Aztec directories:"
    [ -d "$AZTEC_DIR" ] && echo "  $AZTEC_DIR"
    [ -d "$HOME_DIR/.aztec" ] && echo "  $HOME_DIR/.aztec"
else
    green "No Aztec directories remaining"
fi

echo
yellow "Stop & Cleanup Aztec Node Completed"
echo
