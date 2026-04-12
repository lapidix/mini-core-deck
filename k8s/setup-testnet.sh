#!/bin/bash
set -e

# =============================================================================
# setup-testnet.sh — Create kind cluster and deploy 4-node testnet
# Run from cosmos-research root: bash k8s/setup-testnet.sh
# =============================================================================

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"
TESTNET_DIR="${PROJECT_DIR}/testnet"
KIND_CLUSTER="cosmos-testnet"
DOCKER_CONTEXT="orbstack"
export DOCKER_HOST="unix:///Users/leemingi/.orbstack/run/docker.sock"
export KIND_EXPERIMENTAL_PROVIDER=docker

# --- Pre-flight checks ---
echo ">>> Pre-flight checks..."
if [ ! -d "${TESTNET_DIR}/node0/config" ]; then
    echo "ERROR: testnet directory not found. Run 'bash scripts/init-testnet.sh' first."
    exit 1
fi

for cmd in kind kubectl jq docker; do
    if ! command -v $cmd &> /dev/null; then
        echo "ERROR: $cmd is required but not installed."
        exit 1
    fi
done

echo "  All checks passed."

# --- Create kind cluster ---
echo ">>> Creating kind cluster '${KIND_CLUSTER}'..."
if kind get clusters 2>/dev/null | grep -q "^${KIND_CLUSTER}$"; then
    echo "  Cluster already exists, skipping creation."
else
    kind create cluster --config "${SCRIPT_DIR}/kind-config.yaml" --name "${KIND_CLUSTER}"
fi

# --- Load Docker image ---
echo ">>> Loading minid:latest into kind cluster..."
kind load docker-image minid:latest --name "${KIND_CLUSTER}"

# --- Prepare K8s-adapted configs ---
echo ">>> Preparing K8s-adapted configs..."
K8S_CONFIGS="${TESTNET_DIR}/k8s-configs"
rm -rf "${K8S_CONFIGS}"

# Collect node IDs
declare -a NODE_IDS
for i in 0 1 2 3; do
    NODE_HOME="${TESTNET_DIR}/node${i}"
    NODE_IDS[$i]=$(cd "${PROJECT_DIR}" && ./chain-minimal/minid tendermint show-node-id --home "${NODE_HOME}")
    echo "  node${i} ID: ${NODE_IDS[$i]}"
done

# Create modified configs for each node
for i in 0 1 2 3; do
    NODE_DIR="${K8S_CONFIGS}/node${i}"
    mkdir -p "${NODE_DIR}"

    SRC_CONFIG="${TESTNET_DIR}/node${i}/config"

    # Copy essential config files
    cp "${SRC_CONFIG}/genesis.json" "${NODE_DIR}/"
    cp "${SRC_CONFIG}/config.toml" "${NODE_DIR}/"
    cp "${SRC_CONFIG}/app.toml" "${NODE_DIR}/"
    cp "${SRC_CONFIG}/node_key.json" "${NODE_DIR}/"
    cp "${SRC_CONFIG}/priv_validator_key.json" "${NODE_DIR}/"

    # --- Rewrite config.toml for K8s ---
    CONFIG_FILE="${NODE_DIR}/config.toml"

    # Build K8s persistent_peers (all nodes except self, using K8s service DNS)
    PEERS=""
    for j in 0 1 2 3; do
        if [ "${i}" -ne "${j}" ]; then
            if [ -n "${PEERS}" ]; then
                PEERS="${PEERS},"
            fi
            PEERS="${PEERS}${NODE_IDS[$j]}@minid-node${j}:26656"
        fi
    done

    # Replace persistent_peers (match anything between the quotes)
    sed -i'' -e "s|persistent_peers = \".*\"|persistent_peers = \"${PEERS}\"|" "${CONFIG_FILE}"

    # Fix P2P listen address to standard port
    sed -i'' -e 's|laddr = "tcp://0.0.0.0:2[0-9][0-9]56"|laddr = "tcp://0.0.0.0:26656"|' "${CONFIG_FILE}"

    # Fix RPC listen address: bind to 0.0.0.0 (not 127.0.0.1) so port-forward works
    sed -i'' -e 's|laddr = "tcp://127.0.0.1:2[0-9][0-9]57"|laddr = "tcp://0.0.0.0:26657"|' "${CONFIG_FILE}"

    # Fix pprof address
    sed -i'' -e 's|pprof_laddr = "localhost:6[0-9]60"|pprof_laddr = "localhost:6060"|' "${CONFIG_FILE}"

    # --- Rewrite app.toml for K8s ---
    APP_FILE="${NODE_DIR}/app.toml"

    # Fix gRPC, gRPC-web, API addresses to standard ports
    sed -i'' -e 's|address = "0.0.0.0:9[0-9]90"|address = "0.0.0.0:9090"|' "${APP_FILE}"
    sed -i'' -e 's|address = "0.0.0.0:9[0-9]91"|address = "0.0.0.0:9091"|' "${APP_FILE}"
    sed -i'' -e 's|address = "tcp://localhost:1[0-9]17"|address = "tcp://0.0.0.0:1317"|' "${APP_FILE}"

    # Clean up sed backup files
    rm -f "${NODE_DIR}"/*.toml-e "${NODE_DIR}"/*.json-e

    echo "  Prepared K8s config for node${i}"
done

# --- Create ConfigMaps ---
echo ">>> Creating ConfigMaps..."
for i in 0 1 2 3; do
    NODE_DIR="${K8S_CONFIGS}/node${i}"
    kubectl delete configmap "node${i}-config" --ignore-not-found=true > /dev/null 2>&1
    kubectl create configmap "node${i}-config" \
        --from-file=genesis.json="${NODE_DIR}/genesis.json" \
        --from-file=config.toml="${NODE_DIR}/config.toml" \
        --from-file=app.toml="${NODE_DIR}/app.toml" \
        --from-file=node_key.json="${NODE_DIR}/node_key.json" \
        --from-file=priv_validator_key.json="${NODE_DIR}/priv_validator_key.json"
    echo "  Created configmap node${i}-config"
done

# --- Apply K8s manifests ---
echo ">>> Applying K8s manifests..."
kubectl apply -f "${SCRIPT_DIR}/testnet.yaml"

# --- Wait for pods ---
echo ">>> Waiting for pods to be ready (timeout: 120s)..."
for i in 0 1 2 3; do
    echo "  Waiting for minid-node${i}..."
    kubectl wait --for=condition=Ready pod/minid-node${i} --timeout=120s || {
        echo "ERROR: Pod minid-node${i} failed to become ready"
        echo "--- Logs ---"
        kubectl logs minid-node${i} -c minid --tail=20 2>/dev/null || true
        kubectl logs minid-node${i} -c copy-config 2>/dev/null || true
        exit 1
    }
done

echo ""
echo "=============================================="
echo " K8s Testnet deployed successfully!"
echo "=============================================="
echo ""
echo "Check pods:"
echo "  kubectl get pods"
echo ""
echo "Port-forward node0 RPC to localhost:"
echo "  kubectl port-forward pod/minid-node0 26657:26657"
echo ""
echo "Query block height:"
echo "  curl -s http://localhost:26657/status | jq '.result.sync_info.latest_block_height'"
echo ""
echo "Query slashing signing infos:"
echo "  kubectl exec minid-node0 -c minid -- minid query slashing signing-infos --home /root/.minid"
echo ""
echo "Teardown:"
echo "  bash k8s/teardown.sh"
