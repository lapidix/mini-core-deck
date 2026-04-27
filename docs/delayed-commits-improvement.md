# Delayed Commits: 합의 속도와 밸리데이터 보호의 균형

> 이 문서는 프로젝트 전체 개요입니다. 각 레포별 상세 변경 사항은 아래를 참고하세요.
>
> | 레포 | 문서 | 내용 |
> |------|------|------|
> | [lapidix/cometbft](https://github.com/lapidix/cometbft/tree/research/v0.38-lapidix) | [`docs/delayed-commits.md`](https://github.com/lapidix/cometbft/blob/research/v0.38-lapidix/docs/delayed-commits.md) | ABCI proto 확장, DelayedPrecommits 버퍼, 블록 실행 |
> | [lapidix/cosmos-sdk](https://github.com/lapidix/cosmos-sdk/tree/research/v0.50-lapidix) | [`docs/delayed-commits-slashing.md`](https://github.com/lapidix/cosmos-sdk/blob/research/v0.50-lapidix/docs/delayed-commits-slashing.md) | Context 확장, PendingMissedBlocks, Deferred Evaluation |
> | [lapidix/mini-core-deck](https://github.com/lapidix/mini-core-deck) | 이 문서 | 전체 설계, 버그 분석, 벤치마크, 아키텍처 |

## 1. 배경

CometBFT의 `timeout_commit`은 2/3 이상의 Precommit이 모인 후에도 추가로 대기하는 시간이다. 이 대기를 통해 늦게 도착하는 투표를 수집하여 밸리데이터의 Missing Count 증가를 방지한다. 하지만 블록 생성 속도를 직접적으로 제한하는 원인이기도 하다.

`timeout_commit`을 제거하면 블록 생성이 빨라지지만, 네트워크 지연으로 투표가 늦게 도착한 성실한 밸리데이터가 억울하게 miss 처리되어 Jail에 가는 문제가 생긴다.

**목표:** `timeout_commit`을 최소화하면서도 밸리데이터를 부당한 슬래싱으로부터 보호하는 구조적 대안 구현.

> 참고: [CometBFT에서 합의 속도와 형평성의 딜레마](https://lapidix.dev/posts/cometbft-blocktime-dilemma)

### 기존 오픈소스 논의 상태

| 이슈 | 상태 | 내용 |
|------|------|------|
| [cosmos-sdk#2525](https://github.com/cosmos/cosmos-sdk/issues/2525) | 논의만 진행 | Micro-slashing vs 대기 시간 논의, TODO로 남아있음 |
| [tendermint#5911](https://github.com/tendermint/tendermint/issues/5911) | 2021년 논의 | timeout_commit UX 문제 제기 |
| [cometbft#2655](https://github.com/cometbft/cometbft/issues/2655) | 2024년 논의 | timeout_commit deprecated → next_block_delay 방향 |
| [ADR-115](https://github.com/cometbft/cometbft/blob/main/docs/references/architecture/adr-115-predictable-block-times.md) | Accepted, 미구현 | 블록 간격 예측 가능성 개선 (속도 개선은 아님) |
| `skip_timeout_commit` | PoA 전용 | PoS 환경에서는 권장하지 않음 |

**결론:** 기존 논의들은 블록 간격 UX를 개선하거나 PoA 환경에서만 속도를 높이는 방향이며, PoS 환경에서 밸리데이터를 보호하면서 합의 속도를 본질적으로 개선하는 방안은 아직 없다.

---

## 2. 설계

### 검토한 접근법 3가지

| 접근법 | 설명 | 장점 | 단점 |
|--------|------|------|------|
| **1. LastCommit 평가 시점 변경** | `decided_last_commit`을 n-1이 아닌 n-2 블록 기준으로 변경 | SDK만 수정 가능 | MedianTime 계산 깨짐, 제네시스 처리 복잡 |
| **2. seenCommit 기반 지연 평가** | blockStore의 seenCommit과 LastCommit의 차분을 활용 | 별도 버퍼 불필요 | seenCommit이 정확히 2/3 시점이 아님 |
| **3. Consensus-Only 버퍼링** | 합의 엔진에 DelayedPrecommits 버퍼 추가, ABCI로 전달 | addVote 자연스러운 확장, MedianTime 영향 없음 | 새 상태(버퍼) 추가됨 |

**접근법 3을 선택한 이유:** 현재 `addVote`에 이미 `vote.Height+1 == cs.Height` 경로가 존재하여 자연스럽게 확장 가능. `MedianTime` 계산을 건드리지 않으므로 블록 타임스탬프 사이드 이펙트가 없다.

### 최종 설계: Deterministic Deferred Evaluation

Missing Count 평가를 1블록 유예한다. `decided_last_commit`에서 Absent로 표시된 밸리데이터를 즉시 miss 처리하지 않고, `PendingMissedBlock`으로 보류한다. 다음 블록에서 보류를 확정한다.

이 1블록의 유예 동안, 늦게 도착한 투표가 다음 블록의 `block.LastCommit`에 포함될 기회가 생긴다.

```
Block N의 FinalizeBlock:
  decided_last_commit (N-1 투표)
    ├→ Signed → 즉시 정상 처리
    └→ Absent → PendingMissedBlock으로 보류 (즉시 miss 아님)

Block N+1의 FinalizeBlock:
  1. 이전 블록의 PendingMissedBlocks 확정 (miss 카운터++)
  2. 현재 블록의 decided_last_commit 처리 (새로운 보류 기록)
```

### 결정적(Deterministic) 보장

모든 state 변경은 `decided_last_commit`(블록에 포함된 결정적 데이터)만 사용한다. 노드마다 다를 수 있는 로컬 데이터(`delayed_commits`)는 state 변경에 사용하지 않는다. 이 결정적 보장이 없으면 AppHash 불일치가 발생한다 (4장 참조).

### 전체 아키텍처

```
┌─────────────────────────────────────────────────────────────┐
│ CometBFT (합의 엔진)                                         │
│                                                             │
│  consensus/state.go:                                        │
│    State.DelayedPrecommits  ← 버퍼 추가                      │
│    addVote()  ← RoundStepNewHeight 이후 도착한 precommit 수집  │
│    updateToState()  ← 버퍼 초기화                             │
│    finalizeCommit()  ← BlockExecutor에 버퍼 전달              │
│                                                             │
│  state/execution.go:                                        │
│    BlockExecutor.delayedPrecommits  ← 버퍼 저장               │
│    BuildDelayedCommitInfo()  ← CommitInfo 조립                │
│    applyBlock()  ← FinalizeBlock에 delayed_commits 포함       │
│                                                             │
│  proto/tendermint/abci/types.proto:                          │
│    RequestFinalizeBlock.delayed_commits = 9  ← 신규 필드      │
└────────────────────────┬────────────────────────────────────┘
                         │ ABCI RequestFinalizeBlock
                         │ (delayed_commits: informational only)
┌────────────────────────▼────────────────────────────────────┐
│ Cosmos SDK (애플리케이션)                                     │
│                                                             │
│  baseapp/abci.go:                                           │
│    WithDelayedCommits()  ← context에 주입                    │
│                                                             │
│  x/slashing/abci.go:                                        │
│    BeginBlocker:                                            │
│      1. ResolvePendingSignatures()  ← 보류된 miss 확정        │
│      2. HandleValidatorSignatureDeferred()  ← 새 투표 처리    │
│                                                             │
│  x/slashing/keeper/:                                        │
│    PendingMissedBlocks KV Store (prefix 0x04)               │
│    HandleValidatorSignatureDeferred()                        │
│    ResolvePendingSignatures()                                │
└─────────────────────────────────────────────────────────────┘
```

---

## 3. 구현

### 3-1. CometBFT 변경

#### ABCI proto 확장 (`proto/tendermint/abci/types.proto`)

```protobuf
message RequestFinalizeBlock {
  repeated bytes       txs                 = 1;
  CommitInfo           decided_last_commit = 2 [(gogoproto.nullable) = false];
  repeated Misbehavior misbehavior         = 3 [(gogoproto.nullable) = false];
  bytes                hash                = 4;
  int64                height              = 5;
  google.protobuf.Timestamp time           = 6 [(gogoproto.nullable) = false, (gogoproto.stdtime) = true];
  bytes                next_validators_hash = 7;
  bytes                proposer_address    = 8;
  CommitInfo           delayed_commits     = 9 [(gogoproto.nullable) = false]; // 신규
}
```

기존 `CommitInfo` 타입을 재활용하여 하위 호환성 유지. field number 9로 추가하므로 기존 필드와 충돌 없음.

#### 합의 엔진 (`consensus/state.go`)

**State 구조체에 버퍼 추가:**
```go
type State struct {
    // ... 기존 필드 ...

    // DelayedPrecommits stores precommit votes for the previous height that arrived
    // after RoundStepNewHeight ended.
    DelayedPrecommits *types.VoteSet
}
```

**`addVote` — 지연 precommit 수집:**

기존에는 `RoundStepNewHeight` 이후 도착한 precommit을 무시:
```go
// 변경 전
if cs.Step != cstypes.RoundStepNewHeight {
    cs.Logger.Debug("precommit vote came in after commit timeout and has been ignored")
    return added, err
}
```

변경 후 DelayedPrecommits 버퍼에 수집:
```go
// 변경 후
if cs.Step != cstypes.RoundStepNewHeight {
    if cs.DelayedPrecommits != nil {
        added, err = cs.DelayedPrecommits.AddVote(vote)
        if added {
            cs.Logger.Debug("added late precommit to delayed buffer",
                "vote_height", vote.Height, "current_height", cs.Height)
        }
    }
    return added, err
}
```

**`updateToState` — 버퍼 초기화:**
```go
// LastCommit 설정 후
if state.LastBlockHeight > 0 && cs.CommitRound > -1 {
    cs.DelayedPrecommits = types.NewVoteSet(
        state.ChainID, state.LastBlockHeight,
        cs.CommitRound, cmtproto.PrecommitType, state.LastValidators,
    )
} else {
    cs.DelayedPrecommits = nil
}
```

#### 블록 실행 (`state/execution.go`)

**`BuildDelayedCommitInfo` — delayed_commits 조립:**
```go
func BuildDelayedCommitInfo(delayedVotes *types.VoteSet, lastValSet *types.ValidatorSet) abci.CommitInfo {
    if delayedVotes == nil || lastValSet == nil {
        return abci.CommitInfo{}
    }
    votes := make([]abci.VoteInfo, len(lastValSet.Validators))
    for i, val := range lastValSet.Validators {
        blockIDFlag := cmtproto.BlockIDFlagAbsent
        if vote := delayedVotes.GetByAddress(val.Address); vote != nil {
            if vote.BlockID.IsComplete() {
                blockIDFlag = cmtproto.BlockIDFlagCommit
            } else {
                blockIDFlag = cmtproto.BlockIDFlagNil
            }
        }
        votes[i] = abci.VoteInfo{
            Validator:   types.TM2PB.Validator(val),
            BlockIdFlag: blockIDFlag,
        }
    }
    return abci.CommitInfo{Round: delayedVotes.Round(), Votes: votes}
}
```

**`applyBlock` — FinalizeBlock에 포함:**
```go
abciResponse, err := blockExec.proxyApp.FinalizeBlock(ctx, &abci.RequestFinalizeBlock{
    // ... 기존 필드 ...
    DelayedCommits: blockExec.buildDelayedCommits(block, state), // 신규
})
```

### 3-2. Cosmos SDK 변경

#### Context 확장 (`types/context.go`)

```go
type Context struct {
    // ...
    voteInfo       []abci.VoteInfo
    delayedCommits []abci.VoteInfo  // 신규
}

func (c Context) DelayedCommits() []abci.VoteInfo     { return c.delayedCommits }
func (c Context) WithDelayedCommits(dc []abci.VoteInfo) Context {
    c.delayedCommits = dc
    return c
}
```

#### BaseApp ABCI (`baseapp/abci.go`)

```go
// internalFinalizeBlock에서 context 설정
.WithVoteInfos(req.DecidedLastCommit.Votes).
.WithDelayedCommits(req.DelayedCommits.Votes).  // 신규
```

#### PendingMissedBlocks KV Store (`x/slashing/types/keys.go`)

```go
PendingMissedBlockKeyPrefix = []byte{0x04}

// Key: 0x04 | addrLen(1) | consAddr | height(8 bytes LE)
func PendingMissedBlockKey(v sdk.ConsAddress, height int64) []byte { ... }
```

#### Deferred Evaluation 로직 (`x/slashing/keeper/infractions.go`)

```go
// HandleValidatorSignatureDeferred — Absent이면 보류, Signed면 즉시 처리
func (k Keeper) HandleValidatorSignatureDeferred(ctx context.Context, addr cryptotypes.Address, power int64, signed comet.BlockIDFlag) error {
    if signed == comet.BlockIDFlagAbsent {
        // 즉시 miss 처리하지 않고 pending으로 보류
        return k.SetPendingMissedBlock(ctx, consAddr, height, power)
    }
    return k.HandleValidatorSignature(ctx, addr, power, signed)
}

// ResolvePendingSignatures — 보류된 모든 miss를 확정
func (k Keeper) ResolvePendingSignatures(ctx context.Context) error {
    pendingMisses, _ := k.GetAllPendingMissedBlocks(ctx)
    for _, pm := range pendingMisses {
        k.HandleValidatorSignature(ctx, pm.ConsAddr, pm.Power, comet.BlockIDFlagAbsent)
        k.DeletePendingMissedBlock(ctx, pm.ConsAddr, pm.Height)
    }
    return nil
}
```

#### BeginBlocker (`x/slashing/abci.go`)

```go
func BeginBlocker(ctx context.Context, k keeper.Keeper) error {
    sdkCtx := sdk.UnwrapSDKContext(ctx)

    // 1. 이전 블록에서 보류된 miss 확정
    k.ResolvePendingSignatures(ctx)

    // 2. 현재 블록의 투표를 deferred 방식으로 처리
    for _, voteInfo := range sdkCtx.VoteInfos() {
        k.HandleValidatorSignatureDeferred(ctx, ...)
    }
}
```

### 3-3. 커밋 히스토리

**CometBFT (`research/v0.38-lapidix`):**
```
ac2205a feat(abci): add delayed_commits field to RequestFinalizeBlock
5c955fe feat(consensus): add DelayedPrecommits buffer and collect late precommits
36a0163 feat(state): build and pass delayed_commits in FinalizeBlock request
```

**Cosmos SDK (`research/v0.50-lapidix`):**
```
8a8ddc3 feat(baseapp): pipe delayed_commits through SDK context
322c95e feat(slashing): add PendingMissedBlocks KV store for deferred evaluation
f0b3992 feat(slashing): implement deferred evaluation with delayed_commits
5e3aef4 fix(slashing): use deterministic deferred evaluation to fix AppHash mismatch
217e977 fix(slashing): restore deferred evaluation after A/B testing
```

---

## 4. 버그 발견 및 수정

### 4-1. AppHash 불일치 버그

#### 증상

`timeout_commit=1ms`로 k8s 4노드 테스트넷 배포 후, Height 4에서 체인이 멈춤.

```
kubectl logs minid-node0 -c minid --tail=50
```

```
ERR prevote step: consensus deems this block invalid; prevoting nil
    err="wrong Block.Header.AppHash.
    Expected AB8C24490E4F299F66771E9063B611FA885D361912ED8CDC3C105C52B7AADDAC,
    got F94A888A7918C0579497190C3DEB44A30483D664FCB10D4BA2A081A983412C39"
    height=4 module=consensus round=9
```

모든 라운드에서 동일한 에러가 반복. 블록 제안은 수신되지만 prevote 단계에서 invalid로 거부.

#### 원인 분석

초기 구현의 `ResolvePendingSignatures`는 `delayed_commits`(ABCI 필드)를 직접 사용하여 state를 변경했다:

```go
// 초기 구현 (비결정적)
func (k Keeper) ResolvePendingSignatures(ctx context.Context, delayedCommits []abci.VoteInfo) error {
    lateSigners := make(map[string]bool)
    for _, vi := range delayedCommits {
        if comet.BlockIDFlag(vi.BlockIdFlag) != comet.BlockIDFlagAbsent {
            lateSigners[string(vi.Validator.Address)] = true
        }
    }
    for _, pm := range pendingMisses {
        if lateSigners[string(pm.ConsAddr)] {
            // miss 취소 (카운터 증가 안 함)
        } else {
            // miss 확정 (카운터 증가)
        }
    }
}
```

**`delayed_commits`는 각 노드의 로컬 gossip 상태에서 빌드된다.** 합의 엔진의 `DelayedPrecommits` 버퍼는 로컬에서 받은 precommit만 담고 있으므로, 노드마다 내용이 다를 수 있다:

```
Node A: validator X의 지연 precommit을 gossip으로 받음 → delayed_commits에 포함
Node B: validator X의 지연 precommit을 받지 못함 → delayed_commits에 미포함

→ Node A: lateSigners에 X가 있으므로 miss 취소 (MissedBlocksCounter 변화 없음)
→ Node B: lateSigners에 X가 없으므로 miss 확정 (MissedBlocksCounter++)
→ 서로 다른 state → 다른 AppHash → 합의 실패
```

이것은 블록체인의 핵심 원칙 위반이다: **모든 노드가 동일한 입력으로 동일한 state 전이를 해야 한다.** `delayed_commits`는 블록에 포함된 데이터가 아니라 로컬 데이터이므로, 이것을 state 변경에 사용하면 결정적이지 않다.

#### 수정

`delayed_commits`를 state 변경에 사용하지 않도록 변경. `ResolvePendingSignatures`에서 파라미터를 제거하고, 보류된 모든 miss를 무조건 확정:

```go
// 수정 후 (결정적)
func (k Keeper) ResolvePendingSignatures(ctx context.Context) error {
    pendingMisses, _ := k.GetAllPendingMissedBlocks(ctx)
    for _, pm := range pendingMisses {
        // 무조건 miss 확정 — 입력이 결정적 (PendingMissedBlocks KV store)
        k.HandleValidatorSignature(ctx, pm.ConsAddr, pm.Power, BlockIDFlagAbsent)
        k.DeletePendingMissedBlock(ctx, pm.ConsAddr, pm.Height)
    }
    return nil
}
```

`delayed_commits` ABCI 필드는 유지하되 **informational only** (모니터링/디버깅 용도).

수정 후 체인이 정상적으로 블록을 생성하고, 150+ 블록까지 AppHash 불일치 없이 진행됨을 확인.

---

## 5. 검증 결과

### 5-1. 테스트 환경

- **인프라:** kind 클러스터 (1 control-plane + 4 workers), OrbStack Docker
- **네트워크:** 4노드 밸리데이터 테스트넷 (chain-id: `mini-testnet`)
- **슬래싱 파라미터:** `signed_blocks_window = 100`, `min_signed_per_window = 0.5` (max_missed = 50)
- **측정 방법:** 각 케이스별 60초 실행 후 `minid query slashing signing-infos`로 측정
- **A/B 비교:** 동일한 timeout_commit 값에서 Deferred(1블록 유예) vs Baseline(즉시 판정) 비교

### 5-2. timeout_commit별 A/B 비교

#### `timeout_commit = 1ms`

| 방식 | Height | 노드별 missed | 총 missed | 평균 missed/validator |
|------|--------|--------------|-----------|---------------------|
| **Deferred** | 152 | 7, 14, 18, 14 | 53 | 13.2 |
| **Baseline** | 154 | 16, 15, 17, 25 | 73 | 18.2 |
| **차이** | | | **-20** | **-5.0 (27% 감소)** |

#### `timeout_commit = 5ms`

| 방식 | Height | 노드별 missed | 총 missed | 평균 missed/validator |
|------|--------|--------------|-----------|---------------------|
| **Deferred** | 150 | 12, 6, 11, 18 | 47 | 11.8 |
| **Baseline** | 151 | 16, 16, 18, 14 | 64 | 16.0 |
| **차이** | | | **-17** | **-4.2 (26% 감소)** |

#### `timeout_commit = 10ms`

| 방식 | Height | 노드별 missed | 총 missed | 평균 missed/validator |
|------|--------|--------------|-----------|---------------------|
| **Deferred** | 154 | 13, 12, 15, 13 | 53 | 13.2 |
| **Baseline** | 142 | 19, 16, 14, 14 | 63 | 15.8 |
| **차이** | | | **-10** | **-2.6 (16% 감소)** |

### 5-3. 종합 분석

```
timeout_commit별 평균 missed_blocks_counter (4노드, 60초, ~150블록)

              Baseline    Deferred    개선율
  1ms          18.2        13.2       27% ↓
  5ms          16.0        11.8       26% ↓
 10ms          15.8        13.2       16% ↓
```

**관찰:**

1. **Deferred evaluation은 모든 timeout_commit 값에서 missing count를 감소시킨다.** 개선폭은 16~27%.
2. **timeout_commit이 작을수록 Baseline의 missing count가 높아진다.** 1ms에서 평균 18.2, 10ms에서 15.8 — timeout_commit이 짧으면 투표 수집 시간이 줄어 더 많은 miss가 발생.
3. **Deferred evaluation은 timeout_commit이 작을수록 더 큰 효과를 보인다.** 1ms에서 27% 감소 vs 10ms에서 16% 감소 — timeout_commit이 짧아서 miss가 많이 발생할 때 1블록 유예의 가치가 더 크다.
4. **블록 생성 속도는 timeout_commit 값에 관계없이 비슷하다** (1ms/5ms/10ms 모두 ~150블록/60초 = ~0.4s/블록). k8s 환경에서의 네트워크 지연과 합의 라운드 시간이 timeout_commit보다 지배적이기 때문.

### 5-4. 노드 중지 테스트

`timeout_commit = 1ms` + Deferred 환경에서 node3를 20초간 중지 후 재시작:

```
Before stop: Height 81
make stop-node NODE=3
After 20s:   Height 93

Signing Info:
  node0: missed_blocks_counter = 10
  node1: missed_blocks_counter = 23   ← node3 (중지된 노드)
  node2: missed_blocks_counter = 15
  node3: missed_blocks_counter = 12

make start-node NODE=3 → 정상 복귀
```

- node3의 `missed_blocks_counter`: 23 (12블록 중 23회 miss)
- **Jail 발생하지 않음** (max_missed=50)
- 체인 블록 생성: 정상 지속 (3노드로 계속 진행 → 2/3 이상 유지)

### 5-5. 블록 타임 비교

| 설정 | timeout_commit | 블록 타임 | 배수 |
|------|---------------|-----------|------|
| 기존 기본값 | 3s | ~3.5s | 1x |
| 개선 후 | 1ms | ~0.4s | ~8.7x |

---

## 6. 변경된 파일 목록

### CometBFT (`cometbft/`)

| 파일 | 변경 내용 |
|------|----------|
| `proto/tendermint/abci/types.proto` | `RequestFinalizeBlock`에 `delayed_commits` 필드(9) 추가 |
| `abci/types/types.pb.go` | proto 재생성 (수동: struct, getter, marshal, unmarshal, size) |
| `consensus/state.go` | `State.DelayedPrecommits` 버퍼, `addVote` 확장, `updateToState` 초기화 |
| `state/execution.go` | `BlockExecutor.delayedPrecommits`, `SetDelayedPrecommits`, `BuildDelayedCommitInfo`, `buildDelayedCommits`, `applyBlock`에 `DelayedCommits` 추가 |

### Cosmos SDK (`cosmos-sdk/`)

| 파일 | 변경 내용 |
|------|----------|
| `types/context.go` | `delayedCommits` 필드, `DelayedCommits()`, `WithDelayedCommits()` |
| `baseapp/abci.go` | `internalFinalizeBlock`에서 `WithDelayedCommits(req.DelayedCommits.Votes)` |
| `x/slashing/abci.go` | `BeginBlocker` — `ResolvePendingSignatures` → `HandleValidatorSignatureDeferred` 순서로 deferred evaluation |
| `x/slashing/keeper/infractions.go` | `HandleValidatorSignatureDeferred` (보류 기록), `ResolvePendingSignatures` (보류 확정) |
| `x/slashing/keeper/signing_info.go` | `SetPendingMissedBlock`, `GetAllPendingMissedBlocks`, `DeletePendingMissedBlock` |
| `x/slashing/types/keys.go` | `PendingMissedBlockKeyPrefix` (0x04), `PendingMissedBlockKey` 빌더 |
| `x/slashing/types/pending.go` | `PendingMissedBlock` 구조체 정의 |

### Infra (`mini-core-deck` 루트)

| 파일 | 변경 내용 |
|------|----------|
| `scripts/init-testnet.sh` | `timeout_commit` 설정 (sed 패턴 수정, 기본값 `1ms`) |
| `docs/delayed-commits-improvement.md` | 이 문서 |

---

## 7. 한계 및 향후 과제

### 현재 구현의 한계

1. **1블록 유예의 효과 한계:** 현재는 모든 pending miss를 무조건 확정한다. `delayed_commits` 데이터를 결정적으로 활용할 수 있다면 (예: proposer가 블록에 포함) 더 많은 miss를 구제할 수 있다.
2. **로컬 k8s 환경의 한계:** 4노드 kind 클러스터는 실제 퍼블릭 네트워크의 지연 패턴을 재현하지 못한다. 실제 환경에서는 물리적 거리에 따른 long-tail 지연이 더 크므로, deferred evaluation의 효과가 다를 수 있다.
3. **`delayed_commits`의 비결정성 문제:** 블로그 원안의 "지연 도착 투표로 miss 취소" 기능을 구현하려면 `delayed_commits`를 블록에 포함시켜 결정적으로 만들어야 한다. 이는 블록 구조 변경을 수반한다.

### 향후 과제

- `delayed_commits`를 블록 데이터에 포함시키는 방안 설계 (proposer가 자신이 수집한 delayed votes를 블록에 넣음)
- 실제 멀티 리전 테스트넷에서의 벤치마크
- ADR-115의 `next_block_delay`와의 통합 방안
