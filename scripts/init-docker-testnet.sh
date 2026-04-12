#!/bin/bash
set -e

# =============================================================================
# init-docker-testnet.sh — Prepare testnet configs for docker-compose
# Run from cosmos-research root: bash scripts/init-docker-testnet.sh
#
# This script:
# 1. Runs init-testnet.sh to generate base configs
# 2. Copies configs to testnet/docker/nodeN/
# 3. Rewrites persistent_peers to use container names (minid-node0, etc.)
# 4. Fixes ports to standard (26656, 26657, 9090, 1317)
# 5. Binds RPC to 0.0.0.0
# 6. Creates priv_validator_state.json in data dirs
# =============================================================================

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"
TESTNET_DIR="${PROJECT_DIR}/testnet"
DOCKER_DIR="${TESTNET_DIR}/docker"
BINARY="${PROJECT_DIR}/chain-minimal/minid"

# --- Step 1: Run base init if needed ---
if [ ! -d "${TESTNET_DIR}/node0/config" ]; then
    echo ">>> Running base testnet init..."
    bash "${SCRIPT_DIR}/init-testnet.sh"
fi

# --- Step 2: Prepare docker config dirs ---
echo ">>> Preparing docker-compose configs..."
rm -rf "${DOCKER_DIR}"

# Collect node IDs
declare -a NODE_IDS
for i in 0 1 2 3; do
    NODE_IDS[$i]=$("${BINARY}" tendermint show-node-id --home "${TESTNET_DIR}/node${i}")
    echo "  node${i} ID: ${NODE_IDS[$i]}"
done

for i in 0 1 2 3; do
    NODE_DIR="${DOCKER_DIR}/node${i}"
    mkdir -p "${NODE_DIR}/config"
    mkdir -p "${NODE_DIR}/data"

    SRC="${TESTNET_DIR}/node${i}/config"

    # Copy config files
    cp "${SRC}/genesis.json" "${NODE_DIR}/config/"
    cp "${SRC}/config.toml" "${NODE_DIR}/config/"
    cp "${SRC}/app.toml" "${NODE_DIR}/config/"
    cp "${SRC}/node_key.json" "${NODE_DIR}/config/"
    cp "${SRC}/priv_validator_key.json" "${NODE_DIR}/config/"

    CONFIG="${NODE_DIR}/config/config.toml"
    APP="${NODE_DIR}/config/app.toml"

    # --- Rewrite persistent_peers to use container names ---
    PEERS=""
    for j in 0 1 2 3; do
        if [ "${i}" -ne "${j}" ]; then
            if [ -n "${PEERS}" ]; then
                PEERS="${PEERS},"
            fi
            PEERS="${PEERS}${NODE_IDS[$j]}@minid-node${j}:26656"
        fi
    done
    sed -i'' -e "s|persistent_peers = \".*\"|persistent_peers = \"${PEERS}\"|" "${CONFIG}"

    # --- Fix ports to standard (docker-compose maps externally) ---
    sed -i'' -e 's|laddr = "tcp://0.0.0.0:2[0-9][0-9]56"|laddr = "tcp://0.0.0.0:26656"|' "${CONFIG}"
    sed -i'' -e 's|laddr = "tcp://127.0.0.1:2[0-9][0-9]57"|laddr = "tcp://0.0.0.0:26657"|' "${CONFIG}"
    sed -i'' -e 's|pprof_laddr = "localhost:6[0-9]60"|pprof_laddr = "localhost:6060"|' "${CONFIG}"
    sed -i'' -e 's|allow_duplicate_ip = true|allow_duplicate_ip = false|' "${CONFIG}"

    sed -i'' -e 's|address = "0.0.0.0:9[0-9]90"|address = "0.0.0.0:9090"|' "${APP}"
    sed -i'' -e 's|address = "0.0.0.0:9[0-9]91"|address = "0.0.0.0:9091"|' "${APP}"
    sed -i'' -e 's|address = "tcp://localhost:1[0-9]17"|address = "tcp://0.0.0.0:1317"|' "${APP}"

    # Cleanup sed backups
    rm -f "${NODE_DIR}/config/"*.toml-e

    # Create initial priv_validator_state.json in data dir
    echo '{"height":"0","round":0,"step":0}' > "${NODE_DIR}/data/priv_validator_state.json"

    echo "  Prepared docker config for node${i}"
done

echo ""
echo "=============================================="
echo " Docker testnet configs ready!"
echo "=============================================="
echo ""
echo "Start:    docker compose up -d"
echo "Status:   docker compose ps"
echo "Logs:     docker compose logs -f node0"
echo "Stop:     docker compose down"
echo "Cleanup:  docker compose down -v"
