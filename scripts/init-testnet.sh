#!/bin/bash
set -e

# =============================================================================
# init-testnet.sh — Initialize a 4-node local testnet for the mini chain
# Run from the cosmos-research root: bash scripts/init-testnet.sh
# =============================================================================

BINARY="./chain-minimal/minid"
CHAIN_ID="mini-testnet"
TESTNET_DIR="testnet"
DENOM="mini"
NUM_NODES=4

# Per-node port assignments (P2P, RPC, gRPC, gRPC-web, API)
P2P_PORTS=(26656 26756 26856 26956)
RPC_PORTS=(26657 26757 26857 26957)
GRPC_PORTS=(9090 9190 9290 9390)
GRPC_WEB_PORTS=(9091 9191 9291 9391)
API_PORTS=(1317 1417 1517 1617)
PPROF_PORTS=(6060 6160 6260 6360)

VALIDATOR_COINS="10000000${DENOM}"
VALIDATOR_STAKE="1000000${DENOM}"

# Slashing params
SIGNED_BLOCKS_WINDOW="100"
MIN_SIGNED_PER_WINDOW="0.500000000000000000"

# --- Cleanup ---
echo ">>> Cleaning up previous testnet data..."
rm -rf "${TESTNET_DIR}"

# --- Init all nodes ---
echo ">>> Initializing ${NUM_NODES} nodes..."
for i in $(seq 0 $((NUM_NODES - 1))); do
    NODE_HOME="${TESTNET_DIR}/node${i}"
    echo "  Initializing node${i} at ${NODE_HOME}..."
    ${BINARY} init "node${i}" --chain-id "${CHAIN_ID}" --home "${NODE_HOME}" --default-denom "${DENOM}" > /dev/null 2>&1
done

# --- Create validator keys ---
echo ">>> Creating validator keys..."
for i in $(seq 0 $((NUM_NODES - 1))); do
    NODE_HOME="${TESTNET_DIR}/node${i}"
    ${BINARY} keys add "validator${i}" --keyring-backend test --home "${NODE_HOME}" > /dev/null 2>&1
    echo "  Created key validator${i} in node${i}"
done

# --- Use node0 as genesis host ---
GENESIS_HOME="${TESTNET_DIR}/node0"
GENESIS_FILE="${GENESIS_HOME}/config/genesis.json"

# --- Add genesis accounts for all validators (on node0) ---
echo ">>> Adding genesis accounts on node0..."
for i in $(seq 0 $((NUM_NODES - 1))); do
    NODE_HOME="${TESTNET_DIR}/node${i}"
    ADDR=$(${BINARY} keys show "validator${i}" -a --keyring-backend test --home "${NODE_HOME}")
    ${BINARY} genesis add-genesis-account "${ADDR}" "${VALIDATOR_COINS}" --home "${GENESIS_HOME}"
    echo "  Added genesis account for validator${i}: ${ADDR}"
done

# --- Configure slashing params in genesis.json ---
echo ">>> Configuring slashing params in genesis.json..."
# Use a temporary file for jq operations
TMP_GENESIS="${GENESIS_HOME}/config/genesis_tmp.json"

jq ".app_state.slashing.params.signed_blocks_window = \"${SIGNED_BLOCKS_WINDOW}\"" \
    "${GENESIS_FILE}" > "${TMP_GENESIS}" && mv "${TMP_GENESIS}" "${GENESIS_FILE}"

jq ".app_state.slashing.params.min_signed_per_window = \"${MIN_SIGNED_PER_WINDOW}\"" \
    "${GENESIS_FILE}" > "${TMP_GENESIS}" && mv "${TMP_GENESIS}" "${GENESIS_FILE}"

echo "  signed_blocks_window: ${SIGNED_BLOCKS_WINDOW}"
echo "  min_signed_per_window: ${MIN_SIGNED_PER_WINDOW}"

# --- Copy genesis (with all accounts) to all nodes before gentx ---
echo ">>> Copying genesis with accounts to all nodes..."
for i in $(seq 1 $((NUM_NODES - 1))); do
    NODE_HOME="${TESTNET_DIR}/node${i}"
    cp "${GENESIS_FILE}" "${NODE_HOME}/config/genesis.json"
done

# --- Generate gentxs ---
echo ">>> Generating gentxs..."
for i in $(seq 0 $((NUM_NODES - 1))); do
    NODE_HOME="${TESTNET_DIR}/node${i}"
    echo "  Generating gentx for validator${i}..."
    ${BINARY} genesis gentx "validator${i}" "${VALIDATOR_STAKE}" \
        --chain-id "${CHAIN_ID}" \
        --keyring-backend test \
        --home "${NODE_HOME}" \
        --moniker "node${i}" > /dev/null 2>&1

    # Copy gentx to node0 for collection (skip node0 itself)
    if [ "${i}" -ne 0 ]; then
        cp "${NODE_HOME}"/config/gentx/*.json "${GENESIS_HOME}/config/gentx/"
    fi
done

# --- Collect gentxs on node0 ---
echo ">>> Collecting gentxs on node0..."
${BINARY} genesis collect-gentxs --home "${GENESIS_HOME}" > /dev/null 2>&1

# --- Validate genesis ---
echo ">>> Validating genesis..."
${BINARY} genesis validate-genesis --home "${GENESIS_HOME}"

# --- Copy final genesis.json to all nodes ---
echo ">>> Distributing genesis.json to all nodes..."
for i in $(seq 1 $((NUM_NODES - 1))); do
    NODE_HOME="${TESTNET_DIR}/node${i}"
    cp "${GENESIS_FILE}" "${NODE_HOME}/config/genesis.json"
    echo "  Copied genesis.json to node${i}"
done

# --- Collect node IDs ---
echo ">>> Collecting node IDs..."
declare -a NODE_IDS
for i in $(seq 0 $((NUM_NODES - 1))); do
    NODE_HOME="${TESTNET_DIR}/node${i}"
    NODE_IDS[$i]=$(${BINARY} tendermint show-node-id --home "${NODE_HOME}")
    echo "  node${i} ID: ${NODE_IDS[$i]}"
done

# --- Configure ports and persistent_peers for each node ---
echo ">>> Configuring ports and persistent_peers..."
for i in $(seq 0 $((NUM_NODES - 1))); do
    NODE_HOME="${TESTNET_DIR}/node${i}"
    CONFIG_FILE="${NODE_HOME}/config/config.toml"
    APP_CONFIG_FILE="${NODE_HOME}/config/app.toml"

    # Build persistent_peers string (all nodes except self)
    PEERS=""
    for j in $(seq 0 $((NUM_NODES - 1))); do
        if [ "${i}" -ne "${j}" ]; then
            if [ -n "${PEERS}" ]; then
                PEERS="${PEERS},"
            fi
            PEERS="${PEERS}${NODE_IDS[$j]}@127.0.0.1:${P2P_PORTS[$j]}"
        fi
    done

    echo "  Configuring node${i}..."

    # --- config.toml ---

    # P2P listen address
    sed -i'' -e "s|laddr = \"tcp://0.0.0.0:26656\"|laddr = \"tcp://0.0.0.0:${P2P_PORTS[$i]}\"|g" "${CONFIG_FILE}"

    # RPC listen address
    sed -i'' -e "s|laddr = \"tcp://127.0.0.1:26657\"|laddr = \"tcp://127.0.0.1:${RPC_PORTS[$i]}\"|g" "${CONFIG_FILE}"

    # pprof listen address
    sed -i'' -e "s|pprof_laddr = \"localhost:6060\"|pprof_laddr = \"localhost:${PPROF_PORTS[$i]}\"|g" "${CONFIG_FILE}"

    # Persistent peers
    sed -i'' -e "s|persistent_peers = \"\"|persistent_peers = \"${PEERS}\"|g" "${CONFIG_FILE}"

    # Fast block time: timeout_commit = 500ms
    sed -i'' -e 's|timeout_commit = "5s"|timeout_commit = "500ms"|g' "${CONFIG_FILE}"

    # Allow duplicate IPs (needed for localhost multi-node)
    sed -i'' -e 's|allow_duplicate_ip = false|allow_duplicate_ip = true|g' "${CONFIG_FILE}"

    # --- app.toml ---

    # gRPC server address
    sed -i'' -e "s|address = \"0.0.0.0:9090\"|address = \"0.0.0.0:${GRPC_PORTS[$i]}\"|g" "${APP_CONFIG_FILE}"

    # gRPC-web server address
    sed -i'' -e "s|address = \"0.0.0.0:9091\"|address = \"0.0.0.0:${GRPC_WEB_PORTS[$i]}\"|g" "${APP_CONFIG_FILE}"

    # API server address
    sed -i'' -e "s|address = \"tcp://localhost:1317\"|address = \"tcp://localhost:${API_PORTS[$i]}\"|g" "${APP_CONFIG_FILE}"
done

echo ""
echo "=============================================="
echo " Testnet initialized successfully!"
echo "=============================================="
echo ""
echo "Slashing config:"
echo "  signed_blocks_window:  ${SIGNED_BLOCKS_WINDOW}"
echo "  min_signed_per_window: ${MIN_SIGNED_PER_WINDOW} (50%)"
echo "  -> Missing >50 of last 100 blocks triggers jailing"
echo ""
echo "To start all 4 nodes, run each in a separate terminal:"
echo ""
for i in $(seq 0 $((NUM_NODES - 1))); do
    echo "  # Node ${i} (P2P=${P2P_PORTS[$i]}, RPC=${RPC_PORTS[$i]})"
    echo "  ${BINARY} start --home ${TESTNET_DIR}/node${i}"
    echo ""
done
echo "Or start all in background:"
echo ""
echo '  for i in 0 1 2 3; do'
echo "    ${BINARY} start --home ${TESTNET_DIR}/node\${i} > ${TESTNET_DIR}/node\${i}/node.log 2>&1 &"
echo '  done'
echo ""
echo "To stop all nodes:"
echo '  pkill -f "minid start --home testnet"'
echo ""
