#!/usr/bin/env bash
set -Eeuo pipefail

# ---------- Pretty logs ----------
ok(){ echo -e "\033[1;32m$*\033[0m"; }
warn(){ echo -e "\033[1;33m$*\033[0m"; }
err(){ echo -e "\033[1;31m$*\033[0m" >&2; }

trap 'err "Error on line $LINENO. Exiting."' ERR

# ---------- Locate Aztec directory ----------
# Preference: /root/aztec (your earlier setup), fallback to $HOME/aztec
AZTEC_DIR="/root/aztec"
[ -d "$AZTEC_DIR" ] || AZTEC_DIR="$HOME/aztec"
[ -d "$AZTEC_DIR" ] || { err "Aztec directory not found. Create ~/aztec or /root/aztec and try again."; exit 1; }

ENV_FILE="$AZTEC_DIR/.env"
COMPOSE_FILE="$AZTEC_DIR/docker-compose.yml"

[ -f "$ENV_FILE" ] || { err "ENV file not found at $ENV_FILE"; exit 1; }
[ -f "$COMPOSE_FILE" ] || { err "Compose file not found at $COMPOSE_FILE"; exit 1; }

# ---------- Current values ----------
CURR_EXEC=$(grep -E '^ETHEREUM_RPC_URL=' "$ENV_FILE" | sed 's/^ETHEREUM_RPC_URL=//; s/"//g' || true)
CURR_CONS=$(grep -E '^CONSENSUS_BEACON_URL=' "$ENV_FILE" | sed 's/^CONSENSUS_BEACON_URL=//; s/"//g' || true)

echo "Current ETHEREUM_RPC_URL : ${CURR_EXEC:-<not set>}"
echo "Current CONSENSUS_BEACON_URL : ${CURR_CONS:-<not set>}"
echo

# ---------- Prompt input ----------
read -rp "New ETHEREUM_RPC_URL : " NEW_EXEC
[ -n "$NEW_EXEC" ] || { err "ETHEREUM_RPC_URL must not be empty."; exit 1; }

read -rp "New CONSENSUS_BEACON_URL : " NEW_CONS || true

# ---------- Helper to replace or add key ----------
replace_or_add () {
  local key="$1" val="$2" file="$3"
  if grep -qE "^${key}=" "$file"; then
    # Use '|' as sed delimiter to allow URLs with slashes
    sed -i "s|^${key}=.*|${key}=${val}|" "$file"
  else
    echo "${key}=${val}" >> "$file"
  fi
}

# ---------- Backup .env ----------
TS=$(date +%Y%m%d-%H%M%S)
cp -a "$ENV_FILE" "$ENV_FILE.bak.$TS"
ok "Backed up ENV to $ENV_FILE.bak.$TS"

# ---------- Apply changes ----------
replace_or_add "ETHEREUM_RPC_URL" "$NEW_EXEC" "$ENV_FILE"
if [ -n "${NEW_CONS:-}" ]; then
  replace_or_add "CONSENSUS_BEACON_URL" "$NEW_CONS" "$ENV_FILE"
fi

ok "Updated $ENV_FILE"
echo "----- Diff (old vs new) -----"
if command -v diff >/dev/null 2>&1; then
  diff -u "$ENV_FILE.bak.$TS" "$ENV_FILE" || true
else
  warn "diff not available; skipping diff display."
fi
echo "-----------------------------"

# ---------- Choose docker compose command ----------
if docker compose version >/dev/null 2>&1; then
  COMPOSE_CMD="docker compose"
elif command -v docker-compose >/dev/null 2>&1; then
  COMPOSE_CMD="docker-compose"
else
  err "Docker Compose not found."; exit 1
fi

# ---------- Stop & start node ----------
(
  cd "$AZTEC_DIR"
  ok "Stopping Aztec node…"
  if [ "$(id -u)" -eq 0 ]; then
    $COMPOSE_CMD --env-file "$ENV_FILE" down
  else
    sudo $COMPOSE_CMD --env-file "$ENV_FILE" down
  fi

  ok "Starting Aztec node with new RPC…"
  if [ "$(id -u)" -eq 0 ]; then
    $COMPOSE_CMD --env-file "$ENV_FILE" up -d
  else
    sudo $COMPOSE_CMD --env-file "$ENV_FILE" up -d
  fi
)

ok "Done. Aztec node restarted."

echo
echo "Check status:"
echo "  $COMPOSE_CMD -f \"$COMPOSE_FILE\" ps"
echo "Follow logs (Ctrl+C to exit):"
echo "  docker logs -f aztec-sequencer"
