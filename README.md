# mini-core-deck

Mini chain core protocol research deck - build, deploy & test forked CometBFT/SDK on K8s.

## Overview

fork한 CometBFT와 Cosmos SDK를 연결하여 빌드하고, K8s(kind) 기반 4노드 validator 테스트넷에 배포/테스트하기 위한 레포입니다.

3개 fork 레포를 **git submodule**로 포함하고 있으며, `go.work`로 로컬 모듈을 연결하여 빌드합니다.

## Architecture

```
kind cluster (cosmos-testnet)
│
├── control-plane                    ← K8s 마스터 (API server, etcd, scheduler)
│
├── worker (chain-node=0)            ← minid-node0 (validator)
├── worker (chain-node=1)            ← minid-node1 (validator)
├── worker (chain-node=2)            ← minid-node2 (validator)
└── worker (chain-node=3)            ← minid-node3 (validator)
```

- 각 K8s worker에 chain node가 **1:1로 고정** 배치됨 (nodeSelector)
- 노드 간 연결은 `config.toml`의 **persistent_peers**로 설정 (K8s Service DNS 사용)
- control-plane은 K8s 관리만 담당하고 chain node를 실행하지 않음

## 구조

```
mini-core-deck/
├── cometbft/               # [submodule] CometBFT fork (research/v0.38-lapidix)
├── cosmos-sdk/             # [submodule] Cosmos SDK fork (research/v0.50-lapidix)
├── chain-minimal/          # [submodule] Mini chain 앱 코드 (research/v0.50-lapidix)
├── go.work                 # Go workspace - 3개 모듈 로컬 연결
├── Dockerfile              # minid 바이너리 멀티스테이지 빌드
├── k8s/
│   ├── kind-config.yaml    # kind 클러스터 설정 (1 control-plane + 4 workers)
│   ├── testnet.yaml        # 4노드 Pod + Service manifests (nodeSelector로 worker 고정)
│   ├── setup-testnet.sh    # K8s 배포 스크립트
│   └── teardown.sh         # K8s 정리 스크립트
├── scripts/
│   └── init-testnet.sh     # 4노드 테스트넷 초기화 (genesis, keys, config)
└── README.md
```

### Submodules

| 레포 | 브랜치 | 역할 |
|------|--------|------|
| [lapidix/cometbft](https://github.com/lapidix/cometbft) | `research/v0.38-lapidix` | CometBFT fork - 합의 로직 연구 (timeout_commit 등) |
| [lapidix/cosmos-sdk](https://github.com/lapidix/cosmos-sdk) | `research/v0.50-lapidix` | Cosmos SDK fork - slashing missing count 로직 개선 |
| [lapidix/chain-minimal](https://github.com/lapidix/chain-minimal) | `research/v0.50-lapidix` | Mini chain 앱 - auth, bank, staking, distribution, slashing 모듈 |

## Prerequisites

- Go 1.23+
- Docker (OrbStack 또는 Docker Desktop)
- [kind](https://kind.sigs.k8s.io/)
- kubectl
- jq

## Quick Start

### 1. Clone (submodule 포함)

```bash
git clone --recursive https://github.com/lapidix/mini-core-deck.git
cd mini-core-deck
```

이미 clone한 경우 submodule만 가져오기:

```bash
git submodule update --init --recursive
```

### 2. 빌드

```bash
# 로컬 빌드
cd chain-minimal
GOTOOLCHAIN=go1.23.4 go build ./cmd/minid/
cd ..

# Docker 이미지 빌드
docker build -t minid:latest .
```

### 3. 테스트넷 실행 (로컬, K8s 없이)

```bash
# 4노드 초기화
bash scripts/init-testnet.sh

# 4노드 백그라운드 실행
for i in 0 1 2 3; do
  ./chain-minimal/minid start --home testnet/node${i} > testnet/node${i}/node.log 2>&1 &
done

# 중지
pkill -f "minid start --home testnet"
```

### 4. 테스트넷 실행 (K8s / kind)

```bash
# 테스트넷 초기화 (이미 했으면 스킵)
bash scripts/init-testnet.sh

# kind 클러스터 생성 + 배포
bash k8s/setup-testnet.sh

# 정리
bash k8s/teardown.sh
```

## 테스트넷 설정

| 파라미터 | 값 | 설명 |
|----------|-----|------|
| Chain ID | `mini-testnet` | |
| Validators | 4 | node0 ~ node3 |
| Bond denom | `mini` | |
| timeout_commit | `500ms` | 빠른 블록 생성 |
| signed_blocks_window | `100` | 최근 100블록 기준 |
| min_signed_per_window | `50%` | 50% 이상 miss 시 jail |

## 운영 명령어

### 상태 확인

```bash
# Pod 상태 + 어떤 worker에 배치됐는지 확인
kubectl get pods -o wide

# K8s 노드 상태 (control-plane + workers)
kubectl get nodes --show-labels

# 블록 높이
kubectl exec minid-node0 -c minid -- \
  sh -c 'curl -s http://localhost:26657/status' | jq '.result.sync_info.latest_block_height'

# slashing signing info (missed blocks 확인)
kubectl exec minid-node0 -c minid -- \
  minid query slashing signing-infos --home /root/.minid

# validator 상태 (jailed 여부)
kubectl exec minid-node0 -c minid -- \
  minid query staking validators --home /root/.minid --output json \
  | jq '.validators[] | {moniker, jailed, status}'
```

### 로그 확인

```bash
# 특정 노드 로그 (실시간)
kubectl logs minid-node0 -c minid -f

# 최근 50줄
kubectl logs minid-node0 -c minid --tail=50
```

### 포트 포워딩

```bash
# node0 RPC를 localhost:26657로 포워딩 (별도 터미널에서 실행)
kubectl port-forward pod/minid-node0 26657:26657

# 이후 로컬에서 직접 쿼리 가능
curl -s http://localhost:26657/status | jq '.result.sync_info.latest_block_height'
```

### 노드 제어

```bash
# 특정 노드 중지 (Pod 삭제 - 자동 재시작 안 됨)
kubectl delete pod minid-node3 --grace-period=0 --force

# 특정 노드 재시작 (Pod 삭제 후 재생성)
kubectl delete pod minid-node3 --grace-period=0 --force
kubectl apply -f k8s/testnet.yaml
```

## Missing Block → Jail 테스트

```bash
# 1. 현재 signing info 확인 (모든 validator의 missed_blocks_counter = 0)
kubectl exec minid-node0 -c minid -- \
  minid query slashing signing-infos --home /root/.minid

# 2. node3 중지
kubectl delete pod minid-node3 --grace-period=0 --force

# 3. missed_blocks_counter 증가 확인 (반복 실행)
kubectl exec minid-node0 -c minid -- \
  minid query slashing signing-infos --home /root/.minid

# 4. ~100블록 후 (약 50초, timeout_commit=500ms) jailed 확인
#    - missed_blocks_counter가 51 이상 + block height > 100 이후 jail 발동
kubectl exec minid-node0 -c minid -- \
  minid query staking validators --home /root/.minid --output json \
  | jq '.validators[] | {moniker, jailed, status}'
```

## 코드 수정 후 재배포

`go.work`가 3개 submodule을 로컬 연결하고 있으므로, submodule 내 코드를 수정하면 빌드에 즉시 반영됩니다.

```bash
# 1. cometbft 또는 cosmos-sdk 코드 수정

# 2. Docker 이미지 재빌드
docker build -t minid:latest .

# 3. 테스트넷 재배포
bash k8s/teardown.sh
bash scripts/init-testnet.sh
bash k8s/setup-testnet.sh
```

### Submodule 변경사항 커밋

```bash
# submodule 내부에서 커밋 + push
cd cometbft
git add . && git commit -m "feat: ..." && git push
cd ..

# 루트에서 submodule 참조 업데이트
git add cometbft
git commit -m "chore: update cometbft submodule"
git push
```

## License

Apache 2.0
