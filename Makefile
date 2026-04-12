.PHONY: build docker-build init deploy teardown redeploy status logs signing-info validators height help

BINARY = ./chain-minimal/minid
DOCKER_IMAGE = minid:latest

help: ## Show this help
	@grep -E '^[a-zA-Z_-]+:.*?## .*$$' $(MAKEFILE_LIST) | awk 'BEGIN {FS = ":.*?## "}; {printf "  \033[36m%-15s\033[0m %s\n", $$1, $$2}'

# ============================================================
# Build
# ============================================================

build: ## Build minid binary locally
	cd chain-minimal && GOTOOLCHAIN=go1.23.4 go build -o ./minid ./cmd/minid/

docker-build: ## Build Docker image
	docker build -t $(DOCKER_IMAGE) .

# ============================================================
# Testnet Lifecycle
# ============================================================

init: ## Initialize 4-node testnet (genesis, keys, config)
	bash scripts/init-testnet.sh

deploy: ## Deploy testnet to kind cluster
	bash k8s/setup-testnet.sh

teardown: ## Delete kind cluster
	bash k8s/teardown.sh

redeploy: teardown init deploy ## Teardown + init + deploy in one step

# ============================================================
# Monitoring
# ============================================================

status: ## Show pods, nodes, and block height
	@echo "=== K8s Nodes ==="
	@kubectl get nodes -o wide 2>/dev/null || echo "No cluster running"
	@echo ""
	@echo "=== Pods ==="
	@kubectl get pods -o wide 2>/dev/null || echo "No pods"
	@echo ""
	@echo "=== Block Height ==="
	@kubectl exec minid-node0 -c minid -- sh -c 'curl -s http://localhost:26657/status' 2>/dev/null | jq -r '.result.sync_info.latest_block_height' || echo "Cannot reach node"

height: ## Show current block height
	@kubectl exec minid-node0 -c minid -- sh -c 'curl -s http://localhost:26657/status' 2>/dev/null | jq -r '.result.sync_info.latest_block_height'

logs: ## Show node0 logs (use NODE=1 for other nodes)
	kubectl logs minid-node$(or $(NODE),0) -c minid -f

signing-info: ## Show slashing signing info (missed blocks)
	@kubectl exec minid-node0 -c minid -- \
		minid query slashing signing-infos --home /root/.minid --output json 2>/dev/null \
		| jq '.info[] | {address, missed_blocks_counter, jailed_until}'

validators: ## Show validator status (jailed, bonded)
	@kubectl exec minid-node0 -c minid -- \
		minid query staking validators --home /root/.minid --output json 2>/dev/null \
		| jq '.validators[] | {moniker, jailed, status}'

# ============================================================
# Node Control
# ============================================================

stop-node: ## Stop a node (usage: make stop-node NODE=3)
	kubectl delete pod minid-node$(NODE) --grace-period=0 --force

start-node: ## Restart a stopped node (usage: make start-node NODE=3)
	kubectl apply -f k8s/testnet.yaml
