# mini-core-deck

Mini chain core protocol research deck - build, deploy & test forked CometBFT/SDK on K8s.

## Overview

이 레포는 fork한 CometBFT와 Cosmos SDK를 연결하여 빌드하고, K8s(kind) 기반 4노드 validator 테스트넷에 배포/테스트하기 위한 인프라 레포입니다.

### 관련 레포

| 레포 | 브랜치 | 역할 |
|------|--------|------|
| [lapidix/cometbft](https://github.com/lapidix/cometbft) | `research/v0.38-lapidix` | CometBFT fork (합의 로직 연구) |
| [lapidix/cosmos-sdk](https://github.com/lapidix/cosmos-sdk) | `research/v0.50-lapidix` | Cosmos SDK fork (slashing missing count 개선) |
| [lapidix/chain-minimal](https://github.com/lapidix/chain-minimal) | `research/v0.50-lapidix` | Mini chain 앱 코드 (slashing 모듈 wired) |

## 디렉토리 구조

```
mini-core-deck/
├── Dockerfile                  # minid 바이너리 멀티스테이지 빌드
├── k8s/
│   ├── kind-config.yaml        # kind 클러스터 설정
│   ├── testnet.yaml            # 4노드 Pod + Service manifests
│   ├── setup-testnet.sh        # K8s 배포 스크립트
│   └── teardown.sh             # K8s 정리 스크립트
├── scripts/
│   └── init-testnet.sh         # 4노드 테스트넷 초기화 (genesis, keys, config)
└── README.md
```

## Prerequisites

- Go 1.23+
- Docker (OrbStack 또는 Docker Desktop)
- [kind](https://kind.sigs.k8s.io/)
- kubectl
- jq

## Quick Start

### 1. 로컬 환경 구성

```bash
# 이 레포 clone
git clone https://github.com/lapidix/mini-core-deck.git
cd mini-core-deck

# 3개 fork 레포 clone
git clone https://github.com/lapidix/cometbft.git
git clone https://github.com/lapidix/cosmos-sdk.git
git clone https://github.com/lapidix/chain-minimal.git

# 각 레포 연구 브랜치로 checkout
git -C cometbft checkout research/v0.38-lapidix
git -C cosmos-sdk checkout research/v0.50-lapidix
git -C chain-minimal checkout research/v0.50-lapidix

# go.work 생성 (로컬 개발용)
go work init ./cometbft ./cosmos-sdk ./chain-minimal
go work edit -replace github.com/gin-gonic/gin=github.com/gin-gonic/gin@v1.9.1
```

### 2. 빌드

```bash
# 로컬 빌드
cd chain-minimal && GOTOOLCHAIN=go1.23.4 go build ./cmd/minid/ && cd ..

# Docker 이미지 빌드
docker build -t minid:latest .
```

### 3. 테스트넷 실행 (로컬)

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

### 4. 테스트넷 실행 (K8s)

```bash
# 테스트넷 초기화 (이미 했으면 스킵)
bash scripts/init-testnet.sh

# kind 클러스터 생성 + 배포
bash k8s/setup-testnet.sh

# 상태 확인
kubectl get pods
kubectl exec minid-node0 -c minid -- sh -c 'curl -s http://localhost:26657/status' | jq '.result.sync_info.latest_block_height'

# slashing signing info 확인
kubectl exec minid-node0 -c minid -- minid query slashing signing-infos --home /root/.minid

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

## Missing Block → Jail 테스트

```bash
# 노드 하나 중지
kubectl delete pod minid-node3 --grace-period=0 --force

# missed_blocks_counter 증가 확인 (반복 실행)
kubectl exec minid-node0 -c minid -- minid query slashing signing-infos --home /root/.minid

# ~100블록 후 jailed 확인
kubectl exec minid-node0 -c minid -- minid query staking validators --home /root/.minid --output json | jq '.validators[] | {moniker, jailed, status}'
```

## 코드 수정 후 재배포

```bash
# 1. cometbft 또는 cosmos-sdk 코드 수정 (go.work가 자동 참조)

# 2. Docker 이미지 재빌드
docker build -t minid:latest .

# 3. 테스트넷 재배포
bash k8s/teardown.sh
bash scripts/init-testnet.sh
bash k8s/setup-testnet.sh
```

## License

Apache 2.0
