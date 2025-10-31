#!/bin/bash

set -euo pipefail

# --- Configuration ---
AZTEC_DIR="/root/aztec"
ENV_FILE="$AZTEC_DIR/.env"
COMPOSE_FILE="$AZTEC_DIR/docker-compose.yml"
COMPOSE_CMD="docker compose"   # ganti jadi "docker-compose" kalau itu yang ada di server
CONTAINER_NAME="aztec-sequencer"
NEW_GOVERNANCE_PAYLOAD="0xDCd9DdeAbEF70108cE02576df1eB333c4244C666"
SNAPSHOT_URL="--snapshots-url https://files5.blacknodes.net/Aztec/"
AZTEC_IMAGE_VERSION="2.0.4"

echo "### Starting Aztec Node Update Script ###"
echo ""

# --- 0. Basic sanity checks ---
echo "-> Running pre-flight checks..."
if ! command -v docker >/dev/null 2>&1; then
    echo "ERROR: docker command not found. Install Docker first."
    exit 1
fi

if ! command -v ${COMPOSE_CMD%% *} >/dev/null 2>&1 && ! docker compose version >/dev/null 2>&1; then
    echo "ERROR: docker compose not available. Adjust COMPOSE_CMD or install Docker Compose."
    exit 1
fi

if ! command -v aztec-up >/dev/null 2>&1; then
    echo "WARNING: 'aztec-up' not found in PATH. Step 5 may fail."
fi
echo "   ✅ Pre-flight checks done."
echo ""


# --- 1. Update .env file ---
echo "-> Updating $ENV_FILE file..."
if [ ! -f "$ENV_FILE" ]; then
    echo "ERROR: $ENV_FILE file not found!"
    exit 1
fi

# Update GOVERNANCE_PAYLOAD value (replace existing line)
if grep -q "^GOVERNANCE_PAYLOAD=" "$ENV_FILE"; then
    sed -i "s/^GOVERNANCE_PAYLOAD=.*/GOVERNANCE_PAYLOAD=$NEW_GOVERNANCE_PAYLOAD/" "$ENV_FILE"
    echo "   - GOVERNANCE_PAYLOAD value updated."
else
    echo "GOVERNANCE_PAYLOAD=$NEW_GOVERNANCE_PAYLOAD" >> "$ENV_FILE"
    echo "   + GOVERNANCE_PAYLOAD added."
fi

# Ensure AZTEC_ADMIN_PORT exists
if ! grep -q "^AZTEC_ADMIN_PORT=" "$ENV_FILE"; then
    echo "AZTEC_ADMIN_PORT=8880" >> "$ENV_FILE"
    echo "   + Added AZTEC_ADMIN_PORT=8880."
else
    echo "   - AZTEC_ADMIN_PORT already present."
fi

echo "-> .env file successfully updated."
echo ""


# --- 2. Update / recreate docker-compose.yml ---
echo "-> Updating $COMPOSE_FILE file..."

if [ -f "$COMPOSE_FILE" ]; then
    cp "$COMPOSE_FILE" "$COMPOSE_FILE.backup"
    echo "   - Created backup: $COMPOSE_FILE.backup"
else
    echo "   - No existing $COMPOSE_FILE found, will create new one."
fi

# Write a fresh docker-compose.yml with the desired config
cat > "$COMPOSE_FILE" << EOF
services:
  aztec-node:
    container_name: ${CONTAINER_NAME}
    image: aztecprotocol/aztec:${AZTEC_IMAGE_VERSION}
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
      --snapshots-url ${SNAPSHOT_URL}
      --port 8080"
    ports:
      - "40400:40400/tcp"
      - "40400:40400/udp"
      - "8080:8080"
      - "8880:8880"
    volumes:
      - "/root/.aztec/testnet/data/:/data"
EOF

echo "   ✅ Wrote new $COMPOSE_FILE with snapshot URL and admin port"
echo "-> docker-compose.yml file successfully updated."
echo ""


# --- 3. Stop and Remove Old Container ---
echo "-> Stopping and removing container '$CONTAINER_NAME'..."
if docker ps -a --format '{{.Names}}' | grep -q "^${CONTAINER_NAME}\$"; then
    docker stop "${CONTAINER_NAME}" || true
    docker rm -f "${CONTAINER_NAME}" || true
    echo "   - Old container stopped and removed."
else
    echo "   - Container '$CONTAINER_NAME' not found, skipping stop/remove."
fi
echo ""


# --- 4. Clean up old data ---
echo "-> Cleaning up old data directories..."

if [ -d "/root/.aztec/testnet/data" ]; then
    rm -rf /root/.aztec/testnet/data
    echo "   - Removed /root/.aztec/testnet/data"
else
    echo "   - /root/.aztec/testnet/data not found, skipping"
fi

if ls /tmp/aztec-world-state-* 1> /dev/null 2>&1; then
    rm -rf /tmp/aztec-world-state-*
    echo "   - Removed /tmp/aztec-world-state-* files"
else
    echo "   - No /tmp/aztec-world-state-* files found, skipping"
fi
echo ""


# --- 5. Update aztec image/version via aztec-up ---
echo "-> Updating Aztec binaries/images to version ${AZTEC_IMAGE_VERSION}..."
if command -v aztec-up >/dev/null 2>&1; then
    aztec-up -v "${AZTEC_IMAGE_VERSION}"
    echo "   ✅ aztec-up finished."
else
    echo "   ⚠️  Skipping aztec-up (command not found). Make sure your image tag ${AZTEC_IMAGE_VERSION} pulls correctly."
fi
echo ""


# --- 6. Restart Container ---
echo "-> Restarting container with new configuration..."
cd "$AZTEC_DIR" || { echo "ERROR: Cannot enter directory $AZTEC_DIR"; exit 1; }

# Validate docker-compose.yml first
echo "-> Validating docker-compose.yml..."
if $COMPOSE_CMD config -q; then
    echo "   ✅ docker-compose.yml is valid"
else
    echo "   ❌ docker-compose.yml is invalid, restoring backup"
    if [ -f "$COMPOSE_FILE.backup" ]; then
        cp "$COMPOSE_FILE.backup" "$COMPOSE_FILE"
        echo "   -> Restored $COMPOSE_FILE from backup"
    fi
    exit 1
fi

# Bring up container
$COMPOSE_CMD up -d
echo "-> Container started (detached). Giving node time to come up..."
sleep 30
echo ""


# --- 7. Check container status ---
echo "-> Checking container status..."
if docker ps --format '{{.Names}}' | grep -q "^${CONTAINER_NAME}\$"; then
    echo "   ✅ Container '${CONTAINER_NAME}' is running"

    echo "-> Checking container logs for snapshot-related errors..."
    docker logs "${CONTAINER_NAME}" --tail=50 | grep -i "snapshot\|error\|404" || echo "   No snapshot-related errors found in recent logs"

    echo "-> Verifying snapshots-url in container command..."
    if docker inspect "${CONTAINER_NAME}" | grep -q "snapshots-url"; then
        echo "   ✅ snapshots-url parameter found in container command"
    else
        echo "   ⚠️  snapshots-url parameter NOT found in container command"
    fi
else
    echo "   ❌ Container is not running. Dumping 'docker ps -a'..."
    docker ps -a
    exit 1
fi
echo ""


# --- 8. Send New Configuration via RPC ---
echo "-> Sending governance payload configuration update via admin RPC (port 8880)..."
sleep 10

curl_response=$(curl -s -w "%{http_code}" -X POST http://localhost:8880 \
  -H 'Content-Type: application/json' \
  -d '{
    "jsonrpc":"2.0",
    "method":"nodeAdmin_setConfig",
    "params":[{"governanceProposerPayload":"'"$NEW_GOVERNANCE_PAYLOAD"'"}],
    "id":1
  }' 2>/dev/null || echo "CURL_ERROR 000")

http_code=${curl_response: -3}
response_body=${curl_response%???}

if [ "$http_code" -eq 200 ]; then
    echo "   ✅ Governance payload updated successfully"
    echo "   Response: $response_body"
elif [ "$http_code" -eq 000 ]; then
    echo "   ⚠️  Admin RPC on :8880 not ready yet. You may need to retry the nodeAdmin_setConfig call manually."
else
    echo "   ⚠️  Warning: Could not update governance payload (HTTP $http_code)"
    echo "   Response: $response_body"
fi
echo ""


# --- 9. Final status summary ---
echo "### Script Completed ###"
echo "Your Aztec Node has been updated and reconfigured. ✅"
echo ""
echo "### Final Status ###"
echo "Container: $(docker ps --filter "name=${CONTAINER_NAME}" --format "{{.Names}}: {{.Status}}")"
echo "Snapshot URL configured in compose: ${SNAPSHOT_URL}"
echo "Image version: ${AZTEC_IMAGE_VERSION}"
echo "Governance payload in .env: $(grep '^GOVERNANCE_PAYLOAD=' "$ENV_FILE" | cut -d= -f2-)"
echo ""
