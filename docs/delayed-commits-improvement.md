# Delayed Commits: 합의 속도와 밸리데이터 보호의 균형

## 1. 배경

CometBFT의 `timeout_commit`은 2/3 이상의 Precommit이 모인 후에도 추가로 대기하는 시간이다. 이 대기를 통해 늦게 도착하는 투표를 수집하여 밸리데이터의 Missing Count 증가를 방지한다. 하지만 블록 생성 속도를 직접적으로 제한하는 원인이기도 하다.

`timeout_commit`을 제거하면 블록 생성이 빨라지지만, 네트워크 지연으로 투표가 늦게 도착한 성실한 밸리데이터가 억울하게 miss 처리되어 Jail에 가는 문제가 생긴다.

**목표:** `timeout_commit`을 최소화하면서도 밸리데이터를 부당한 슬래싱으로부터 보호하는 구조적 대안 구현.

> 참고: [CometBFT에서 합의 속도와 형평성의 딜레마](https://lapidix.dev/posts/cometbft-blocktime-dilemma)

---

## 2. 설계

### 접근법: Deterministic Deferred Evaluation

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

모든 state 변경은 `decided_last_commit`(블록에 포함된 결정적 데이터)만 사용한다. 노드마다 다를 수 있는 로컬 데이터(`delayed_commits`)는 state 변경에 사용하지 않는다.

---

## 3. 구현

### 3-1. CometBFT 변경

**ABCI proto** (`proto/tendermint/abci/types.proto`):
```protobuf
message RequestFinalizeBlock {
  // ... 기존 필드 ...
  CommitInfo delayed_commits = 9 [(gogoproto.nullable) = false]; // 신규 (informational)
}
```

**합의 엔진** (`consensus/state.go`):
- `State` 구조체에 `DelayedPrecommits *types.VoteSet` 필드 추가
- `updateToState`에서 height 전환 시 버퍼 초기화
- `addVote`에서 `RoundStepNewHeight` 이후 도착한 precommit을 버퍼에 수집

**블록 실행** (`state/execution.go`):
- `BlockExecutor`에 `delayedPrecommits` 필드 + setter 추가
- `BuildDelayedCommitInfo` 함수로 `delayed_commits` 조립
- `applyBlock`의 `FinalizeBlock` 호출에 `DelayedCommits` 필드 추가

### 3-2. Cosmos SDK 변경

**Context** (`types/context.go`, `baseapp/abci.go`):
- `Context`에 `delayedCommits` 필드 + getter/setter 추가
- `internalFinalizeBlock`에서 context에 주입

**슬래싱 모듈** (`x/slashing/`):
- `PendingMissedBlocks` KV Store 추가 (prefix `0x04`)
- `HandleValidatorSignatureDeferred`: Absent → pending 기록, Signed → 즉시 처리
- `ResolvePendingSignatures`: 보류된 miss를 확정
- `BeginBlocker`: resolve → deferred evaluation 순서로 실행

### 3-3. 커밋 히스토리

**CometBFT:**
```
ac2205a feat(abci): add delayed_commits field to RequestFinalizeBlock
5c955fe feat(consensus): add DelayedPrecommits buffer and collect late precommits
36a0163 feat(state): build and pass delayed_commits in FinalizeBlock request
```

**Cosmos SDK:**
```
8a8ddc3 feat(baseapp): pipe delayed_commits through SDK context
322c95e feat(slashing): add PendingMissedBlocks KV store for deferred evaluation
f0b3992 feat(slashing): implement deferred evaluation with delayed_commits
5e3aef4 fix(slashing): use deterministic deferred evaluation to fix AppHash mismatch
```

---

## 4. 버그 발견 및 수정

### 4-1. AppHash 불일치 버그

**증상:** Height 4에서 체인이 멈춤. 로그:
```
ERR prevote step: consensus deems this block invalid; prevoting nil
    err="wrong Block.Header.AppHash.
    Expected AB8C24490E4F..., got F94A888A7918..."
```

**원인 분석:**

초기 구현에서 `delayed_commits` (노드 로컬 gossip 데이터)를 `ResolvePendingSignatures`에서 직접 사용하여 state를 변경했다.

문제: `delayed_commits`는 각 노드의 로컬 gossip 상태에서 빌드된다. 노드 A가 받은 지연 precommit과 노드 B가 받은 지연 precommit이 다를 수 있다. 따라서:

```
Node A: delayed_commits에 validator X의 투표가 있음 → miss 취소
Node B: delayed_commits에 validator X의 투표가 없음 → miss 확정
→ 서로 다른 state → 다른 AppHash → 합의 실패
```

**수정:**

`delayed_commits`를 state 변경에 사용하지 않도록 변경. 대신 `decided_last_commit`(블록에 포함된 결정적 데이터)만 사용하는 순수 1블록 유예 방식으로 전환.

```go
// 수정 전 (비결정적)
func (k Keeper) ResolvePendingSignatures(ctx context.Context, delayedCommits []abci.VoteInfo) error {
    lateSigners := make(map[string]bool)
    for _, vi := range delayedCommits {  // ← 노드마다 다른 데이터!
        if vi.BlockIdFlag != Absent { lateSigners[addr] = true }
    }
    // lateSigners에 있으면 miss 취소 → 비결정적 state 변경
}

// 수정 후 (결정적)
func (k Keeper) ResolvePendingSignatures(ctx context.Context) error {
    pendingMisses, _ := k.GetAllPendingMissedBlocks(ctx)
    for _, pm := range pendingMisses {
        k.HandleValidatorSignature(ctx, pm.ConsAddr, pm.Power, BlockIDFlagAbsent)  // 무조건 확정
        k.DeletePendingMissedBlock(ctx, pm.ConsAddr, pm.Height)
    }
}
```

---

## 5. 검증 결과

### 5-1. 테스트 환경

- kind 클러스터 (1 control-plane + 4 workers)
- 4노드 밸리데이터 테스트넷
- `signed_blocks_window = 100`, `min_signed_per_window = 0.5` (max_missed = 50)
- 각 케이스 60초 동안 ~150블록 생성 후 측정

### 5-2. timeout_commit별 A/B 비교

#### `timeout_commit = 1ms`

| 방식 | Height | 총 missed | 평균 missed/validator | 개선율 |
|------|--------|-----------|---------------------|--------|
| **Deferred (1블록 유예)** | 152 | 53 | 13.2 | — |
| **Baseline (즉시 판정)** | 154 | 73 | 18.2 | — |
| **차이** | | **-20** | **-5.0** | **27% 감소** |

#### `timeout_commit = 5ms`

| 방식 | Height | 총 missed | 평균 missed/validator | 개선율 |
|------|--------|-----------|---------------------|--------|
| **Deferred (1블록 유예)** | 150 | 47 | 11.8 | — |
| **Baseline (즉시 판정)** | 151 | 64 | 16.0 | — |
| **차이** | | **-17** | **-4.2** | **26% 감소** |

#### `timeout_commit = 10ms`

| 방식 | Height | 총 missed | 평균 missed/validator | 개선율 |
|------|--------|-----------|---------------------|--------|
| **Deferred (1블록 유예)** | 154 | 53 | 13.2 | — |
| **Baseline (즉시 판정)** | 142 | 63 | 15.8 | — |
| **차이** | | **-10** | **-2.6** | **16% 감소** |

### 5-3. 종합 분석

```
timeout_commit별 평균 missed/validator (4노드, ~150블록)

              Baseline    Deferred    개선율
  1ms          18.2        13.2       27% ↓
  5ms          16.0        11.8       26% ↓
 10ms          15.8        13.2       16% ↓
```

**관찰 결과:**

1. **Deferred evaluation은 모든 timeout_commit 값에서 missing count를 감소시킨다.** 개선폭은 16~27%.
2. **timeout_commit이 작을수록 Baseline의 missing count가 높아진다.** 1ms에서 평균 18.2, 10ms에서 15.8 — timeout_commit이 짧으면 투표 수집 시간이 줄어 더 많은 miss가 발생.
3. **Deferred evaluation은 timeout_commit이 작을수록 더 큰 효과를 보인다.** 1ms에서 27% 감소 vs 10ms에서 16% 감소 — timeout_commit이 짧아서 miss가 많이 발생할 때 1블록 유예의 가치가 더 크다.
4. **블록 생성 속도는 timeout_commit 값에 관계없이 비슷하다.** 모든 케이스에서 ~150블록/60초 (약 0.4초/블록). 이는 k8s 환경에서의 네트워크 지연과 합의 라운드 시간이 timeout_commit보다 지배적이기 때문.

### 5-4. 노드 중지 테스트

`timeout_commit = 1ms` + Deferred 환경에서 node3를 20초간 중지 후 재시작:
- node3의 `missed_blocks_counter`: 46 (20초 × ~2.5블록/초)
- **Jail 발생하지 않음** (max_missed=50, 46 < 50)
- 나머지 3개 노드: 정상 (missed 10-11)
- 체인 블록 생성: 정상 지속

### 5-5. 블록 타임 비교

| 설정 | timeout_commit | 블록 타임 |
|------|---------------|-----------|
| 기존 기본값 | 3s | ~3.5s |
| 개선 후 | 1ms | ~0.4s |

**~8.7배 블록 생성 속도 향상.**

---

## 6. 변경된 파일 목록

### CometBFT (`cometbft/`)

| 파일 | 변경 내용 |
|------|----------|
| `proto/tendermint/abci/types.proto` | `RequestFinalizeBlock`에 `delayed_commits` 필드(9) 추가 |
| `abci/types/types.pb.go` | proto 재생성 (수동) |
| `consensus/state.go` | `DelayedPrecommits` 버퍼, `addVote` 확장, `updateToState` 수정 |
| `state/execution.go` | `BuildDelayedCommitInfo`, `buildDelayedCommits`, `SetDelayedPrecommits` |

### Cosmos SDK (`cosmos-sdk/`)

| 파일 | 변경 내용 |
|------|----------|
| `types/context.go` | `delayedCommits` 필드, `DelayedCommits()`, `WithDelayedCommits()` |
| `baseapp/abci.go` | `internalFinalizeBlock`에서 `delayed_commits` context 설정 |
| `x/slashing/abci.go` | `BeginBlocker` deferred evaluation 로직 |
| `x/slashing/keeper/infractions.go` | `HandleValidatorSignatureDeferred`, `ResolvePendingSignatures` |
| `x/slashing/keeper/signing_info.go` | `PendingMissedBlock` CRUD 메서드 |
| `x/slashing/types/keys.go` | `PendingMissedBlockKeyPrefix` (0x04) |
| `x/slashing/types/pending.go` | `PendingMissedBlock` 타입 정의 |

### Infra (`mini-core-deck` 루트)

| 파일 | 변경 내용 |
|------|----------|
| `scripts/init-testnet.sh` | `timeout_commit = "1ms"` 설정 |
