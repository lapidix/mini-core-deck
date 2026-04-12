.PHONY: build docker-build help \
	init deploy teardown redeploy \
	compose-init compose-up compose-down compose-restart compose-logs compose-ps \
	status height logs signing-info validators \
	port-forward port-forward-rpc port-forward-grpc \
	stop-node start-node

BINARY = ./chain-minimal/minid
DOCKER_IMAGE = minid:latest
export DOCKER_HOST ?= unix:///Users/leemingi/.orbstack/run/docker.sock

help: ## Show this help
	@grep -E '^[a-zA-Z_-]+:.*?## .*$$' $(MAKEFILE_LIST) | awk 'BEGIN {FS = ":.*?## "}; {printf "  \033[36m%-18s\033[0m %s\n", $$1, $$2}'

# ============================================================
# Build
# ============================================================

build: ## Build minid binary locally
	cd chain-minimal && GOTOOLCHAIN=go1.23.4 go build -o ./minid ./cmd/minid/

docker-build: ## Build Docker image
	docker build -t $(DOCKER_IMAGE) .

# ============================================================
# Docker Compose
# ============================================================

compose-init: ## Initialize testnet configs for docker-compose
	bash scripts/init-docker-testnet.sh

compose-up: ## Start 4-node testnet (docker-compose)
	docker compose up -d

compose-down: ## Stop testnet (docker-compose)
	docker compose down

compose-restart: compose-down compose-up ## Restart testnet (docker-compose)

compose-clean: ## Stop testnet + remove volumes (docker-compose)
	docker compose down -v

compose-redeploy: compose-clean compose-init compose-up ## Full redeploy (docker-compose)

compose-logs: ## Show node0 logs (use NODE=1 for other nodes)
	docker compose logs -f node$(or $(NODE),0)

compose-ps: ## Show container status
	docker compose ps

compose-status: ## Show status + block height (docker-compose)
	@echo "=== Containers ==="
	@docker compose ps 2>/dev/null || echo "Not running"
	@echo ""
	@echo "=== Block Height ==="
	@curl -s http://localhost:26657/status 2>/dev/null | jq -r '.result.sync_info.latest_block_height' || echo "Cannot reach node"

compose-signing-info: ## Show slashing signing info (docker-compose)
	@docker exec minid-node0 minid query slashing signing-infos --home /root/.minid --output json 2>/dev/null \
		| jq '.info[] | {address, missed_blocks_counter, jailed_until}'

compose-validators: ## Show validator status (docker-compose)
	@docker exec minid-node0 minid query staking validators --home /root/.minid --output json 2>/dev/null \
		| jq '.validators[] | {moniker, jailed, status}'

compose-stop-node: ## Stop a node (usage: make compose-stop-node NODE=3)
	docker compose stop node$(NODE)

compose-start-node: ## Start a stopped node (usage: make compose-start-node NODE=3)
	docker compose start node$(NODE)

# ============================================================
# K8s (kind)
# ============================================================

init: ## [k8s] Initialize 4-node testnet
	bash scripts/init-testnet.sh

deploy: ## [k8s] Deploy testnet to kind cluster
	bash k8s/setup-testnet.sh

teardown: ## [k8s] Delete kind cluster
	bash k8s/teardown.sh

redeploy: teardown init deploy ## [k8s] Teardown + init + deploy

status: ## [k8s] Show pods, nodes, and block height
	@echo "=== K8s Nodes ==="
	@kubectl get nodes -o wide 2>/dev/null || echo "No cluster running"
	@echo ""
	@echo "=== Pods ==="
	@kubectl get pods -o wide 2>/dev/null || echo "No pods"
	@echo ""
	@echo "=== Block Height ==="
	@kubectl exec minid-node0 -c minid -- sh -c 'curl -s http://localhost:26657/status' 2>/dev/null | jq -r '.result.sync_info.latest_block_height' || echo "Cannot reach node"

height: ## [k8s] Show current block height
	@kubectl exec minid-node0 -c minid -- sh -c 'curl -s http://localhost:26657/status' 2>/dev/null | jq -r '.result.sync_info.latest_block_height'

logs: ## [k8s] Show node0 logs (use NODE=1 for other nodes)
	kubectl logs minid-node$(or $(NODE),0) -c minid -f

signing-info: ## [k8s] Show slashing signing info
	@kubectl exec minid-node0 -c minid -- \
		minid query slashing signing-infos --home /root/.minid --output json 2>/dev/null \
		| jq '.info[] | {address, missed_blocks_counter, jailed_until}'

validators: ## [k8s] Show validator status
	@kubectl exec minid-node0 -c minid -- \
		minid query staking validators --home /root/.minid --output json 2>/dev/null \
		| jq '.validators[] | {moniker, jailed, status}'

port-forward: ## [k8s] Forward RPC+gRPC of node0 (use NODE=1 for other nodes)
	@echo "Forwarding minid-node$(or $(NODE),0) → localhost:26657 (RPC) + localhost:9090 (gRPC)"
	@echo "Press Ctrl+C to stop"
	kubectl port-forward pod/minid-node$(or $(NODE),0) 26657:26657 9090:9090

port-forward-rpc: ## [k8s] Forward RPC only
	kubectl port-forward pod/minid-node$(or $(NODE),0) 26657:26657

port-forward-grpc: ## [k8s] Forward gRPC only
	kubectl port-forward pod/minid-node$(or $(NODE),0) 9090:9090

stop-node: ## [k8s] Stop a node (usage: make stop-node NODE=3)
	kubectl delete pod minid-node$(NODE) --grace-period=0 --force

start-node: ## [k8s] Restart a stopped node (usage: make start-node NODE=3)
	kubectl apply -f k8s/testnet.yaml
