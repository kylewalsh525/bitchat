# Phase 4 — Payments (Cashu + Multi-Rail Micropayments over Agent Mesh)

Goal: Enable paid LLM agent requests on the mesh with strong privacy defaults, practical offline behavior, and clear security guarantees.

Status: Partial

Note: Phase 4 is feature-complete for beta scope now that Phase 8 product readiness is complete (onboarding, settings IA, wallet UX + mint allowlist consent, macOS P2PK parity, redacted support bundle export, and panic wipe). Phase 4 remains Partial because reputation/incentives are deferred by design.

This Phase 4 plan is written as a PRD + technical design “single doc” that you can lift into specs. It includes an MVP and multiple later-stage milestones (previously discussed as “Phase 5/6/7”), all kept under Phase 4.

---

## Milestone Status Snapshot

- **4A status: Partial (implemented in-tree)**
  - Implemented scope:
    - payment terms in `AgentInfo` (v2)
    - payment-required interstitial flow in `AgentResponsePacket`
    - payment packets: `AgentPaymentPayloadPacket`, `AgentPaymentReceiptPacket`
    - mint proxy packet schemas: `MintProxyRequestPacket`, `MintProxyResponsePacket`
    - local wallet + mint client integration (`CashuWalletService`, `CashuMintClient`)
    - provider/requester payment bridge + store replay/idempotency/session binding
    - payment UI pay action and wallet command surface
    - offline acceptance + later finalization queue
- **4B status: Implemented (baseline + hardening in-tree)**
  - Implemented scope:
    - settlement-room gossip service (`AgentSettlementGossip`)
    - `SpendAnnounce` and `SpendConflict` schema handling
    - bounded seen-nullifier cache + sender rate limiting
    - mesh room gossip handling (`#settle`) in runtime flow
    - optional global room bridge handling (`#settle-global`) when internet relay path exists
    - payment pre-check rejection when nullifiers already appear in settlement gossip
    - hardening: unique global settlement subscription IDs per runtime instance
    - hardening: bounded prune cadence and observation-order compaction under heavy churn
- **4C status: Implemented (baseline execution path in-tree)**
  - Implemented scope:
    - runtime mint proxy request/response handling (`mintProxyRequest`, `mintProxyResponse`)
    - `MintGatewayService` execution for `info`, `keysets`, `swap`, `checkstate`, and `relock`
    - proxy path fallback (`/v1/*` to legacy paths) and HTTP/body safety limits
    - `proxyID` in-flight dedupe and response cache for idempotent retries
    - requester-side multi-gateway retry with timeout handling
    - `CashuMintClient` direct-call fallback to mesh proxy execution
  - Resilience hardening delivered:
    - deterministic `proxyID` generation for retryable mint operations (`swap`/`checkstate`/`relock`)
    - transient gateway failures are not response-cached, so same-`proxyID` retries can recover
    - additional regression coverage for transient-failure retry recovery
- **4D status: Implemented (per-token pricing + tranche streaming baseline in-tree)**
  - Implemented scope:
    - per-token `AgentInfo` payment terms (`priceModel`, `pricePerInputToken`, `pricePerOutputToken`, `minDeposit`, `granularityTokens`)
    - tranche metadata in payment requests (`trancheIndex`, `trancheCount`, `trancheTokenCount`)
    - provider tranche plan execution: partial output release per paid tranche
    - requester payment prompt progression (`tranche N/M`) and sequential `/agentpay` handling
    - streaming pause/resume around `paymentRequired` interstitials to avoid false stream timeout while waiting for next tranche payment
    - payment receipt `paymentID` binding for multi-tranche ordering safety
- **4E status: Implemented (encrypted release baseline in-tree)**
  - Implemented scope:
    - provider precomputes paid response and encrypts to a fair-exchange offer before payment
    - provider sends encrypted offer chunks (`afex1:` payload segments) before payment settlement
    - payment receipt carries unlock token (`fairUnlockKey`) after accepted/finalized payment
    - requester decrypts and renders response from offer + unlock token, including out-of-order packet handling
    - provider still emits plain post-payment response as compatibility fallback (same request message ID)
- **4F status: Implemented (notary + P2PK locking hardening in-tree; reputation deferred)**
  - Implemented scope:
    - opt-in notary capability (`AgentNotaryPolicy.isNotaryCapable`)
    - provider k-of-n offline notary threshold policy (`requiredOfflineSignatures`, timeout policy)
    - notary gossip request/attestation flow (`notary1:` envelopes) across mesh + optional global bridge
    - bridge-side offline acceptance enforcement with receipt collection before `accepted_offline`
    - receipt attachment and persistence (`AgentPaymentReceiptPacket.notaryReceipts`, payment store replay path)
    - payment term lock mode (`requiresLocking`) and defaults (`offline_accepted -> p2pk`, `online_required -> none`)
    - per-request lock key lifecycle (`AgentPaymentLockKeyStore`)
    - requester relock pipeline (direct mint relock first, gateway relock fallback via `MintProxyMethod.relock`)
    - provider fail-closed lock enforcement + lock-bound finalize/sign flow (`CashuP2PKService`)
  - Deferred scope:
    - reputation policy remains intentionally deferred pending privacy-first design review
- **4G status: Partial (x402 baseline in-tree; production facilitator hardening pending)**
  - Implemented scope:
    - rail-agnostic bridge path now supports `cashu` and `x402`
    - `paymentRail` now includes `"x402"` with rail-specific terms in `AgentPaymentTerms`
    - x402 request/payload envelopes (`xreq:`/`xpay:`) are implemented and session-bound
    - requester feature-gated x402 preference controls are in onboarding/settings
    - provider wizard supports x402 chain/token/pay-to/gateway/facilitator config
    - payment interstitial UI renders x402 gateway/chain/token/pay-to context
    - requester wallet bridge supports thirdweb guest-wallet pay path
    - provider bridge settles x402 payloads via `POST /x402/settle` with idempotent replay handling
    - gateway proxy now serves `/x402/prepare` and `/x402/settle` (mock mode default; upstream passthrough configurable)
  - Remaining scope:
    - deployment-specific facilitator contracts/keys and upstream settlement policy hardening
    - optional additional rails (for example Solana) and any incentive layer are still deferred
- **Next target:** Phase 4G production hardening (facilitator upstream contracts + operational policy) or optional incentives, depending on launch goals.

---

## 0) Executive summary

We implement **Cashu** as the default/private rail and **x402** as an optional online-only rail.

- When **any path to the mint exists** (direct internet, or a gateway node with internet), providers finalize payments by **swapping** received proofs at the mint before releasing final output.
- When **no mint is reachable** (true BLE-only, no internet anywhere), we support a **risk-managed offline mode**:
  - validate token authenticity offline (DLEQ if available),
  - apply offline caps + anti-replay,
  - optionally gossip *non-spendable identifiers* (“nullifiers”) inside a mesh settlement room to reduce casual double-spends within a connected component,
  - finalize later when internet returns.

We explicitly do **not** claim perfect double-spend prevention in partitioned offline networks without a mint.

---

## 1) Requirements

### 1.1 Product requirements (PRD)

#### Requester (payer)
- Can discover providers with transparent price + payment rail terms.
- Can pay for a request with a single action (no manual copy/paste commands in normal UX).
- Can operate for long periods with **no internet**, using preloaded ecash notes.
- Has privacy: payment should not require accounts or persistent identifiers; avoid linking prompt content to payment metadata.

#### Provider (agent operator)
- Can set price (MVP: per-request; later: per-token/tranches).
- Can enforce payment gating: **no final response without payment acceptance**.
- Can finalize payment whenever a path to a mint exists.
- Has privacy: can avoid exposing a stable “payment address” or identity; can rotate receiving keys.

#### Network/operator
- Works on BLE mesh with intermittent connectivity and partitions.
- Does not require running a mint on every BLE mesh.
- Scales to many agents without turning payments into a spam or griefing vector.

### 1.2 Security requirements
- **No bearer-proof leakage**: never broadcast raw Cashu proofs in public/room contexts.
- Strong anti-replay: the same payment payload must not be accepted twice for different requests.
- Online finality: if internet (direct or via gateway) exists, provider can obtain mint-backed finality.
- Offline mode must be:
  - clearly labeled as “risk-managed,”
  - capped and auditable,
  - minimized in attack surface (spam, storage DoS).

### 1.3 Privacy requirements
- Minimal metadata leakage over mesh relays:
  - avoid sharing stable identifiers,
  - prefer short-lived request/payment IDs,
  - prefer per-request receiving pubkeys (or per-session rotation).
- Avoid calling “proof state check” endpoints unless necessary; prefer swap finalization when online.
- Settlement room gossip should use hashed nullifiers and avoid amounts where feasible.

---

## 2) Non-goals (Phase 4)
- Running our own stablecoin custody or mint infrastructure in MVP.
- Perfect double-spend prevention in fully offline partitioned networks.
- On-chain per-request escrow, or smart-contract gas-based flows.
- Provider incentive schemes (“capacity interest”) in MVP; that comes later in this same Phase 4 doc as a “later milestone.”

---

## 3) Assumptions & threat model

### 3.1 Connectivity cases we must support
- **Case A: Both sides BLE-only** (no internet anywhere).
- **Case B: Provider has internet** (payer may not).
- **Case C: Payer has internet** (provider may not).
- **Case D: Some node in mesh has internet** (gateway proxy is possible).

### 3.2 Adversary model (payments amplify consequences)
Assume:
- Any relay peer can read, drop, delay, or reorder traffic.
- Public rooms are observable by many participants.
- Attackers can attempt:
  - double-spends,
  - replay of old payment payloads,
  - spam and storage DoS,
  - identity spoofing of “agent” advertisements,
  - correlation attacks across time.

---

## 4) Key concepts & vocabulary

### 4.1 Payment request vs payment payload
- **Payment request**: a provider-generated request string that tells the payer *how much* and *under what conditions* to pay (Cashu NUT-18 “creq…”).
- **Payment payload**: the payer’s response including proofs, mint reference, and payment ID (Cashu NUT-18 payload).

### 4.2 Settlement modes (explicitly advertised by providers)
- `online_required`:
  - Provider only releases final output once it has mint-verified acceptance (swap/melt completed).
- `offline_accepted`:
  - Provider may accept in offline mode (with caps and stricter policies).
  - Provider finalizes later once mint is reachable.

### 4.3 Nullifier (safe-ish identifier for “I’ve seen this proof”)
- We define `nullifier = H(mintURL || unit || Y)` where `Y` is the proof identifier used for state checking (derived from proof secret).
- Nullifiers are used only for:
  - local caches (“seen set”),
  - settlement room gossip (“spent announce”),
  - notary receipts (optional).
- Nullifiers are NOT spendable and do not enable theft.

---

## 5) System architecture

### 5.1 Components (app-side)

**AgentPaymentBridge (rail-agnostic, but Cashu-first)**
- Encodes payment request → UX display
- Builds payment payload from wallet
- Validates incoming payment payloads (provider side)
- Coordinates settlement actions (online swap; offline risk mode)
- Reports status to Chat/Agent layer

**CashuWalletService**
- Stores proofs by mint/unit/keyset
- Selects proofs for payments
- Imports/exports tokens
- Signs witnesses when lock/notary/fair-exchange spending conditions require it

**CashuMintClient**
- Online calls to mint endpoints (info, keysets, swap, checkstate)
- Must support:
  - direct internet transport
  - gateway transport via mesh (proxy)

**MintGatewayService (optional, but recommended early)**
- Any node with internet can proxy mint calls for mesh-only nodes.
- Gateway must be stateless as much as possible; use request IDs for retries.

**AgentSettlementGossip**
- Mesh room `#settle` (and optional global room) for nullifier announcements and conflicts.
- Maintains a rolling set/bloom of seen nullifiers.

**AgentPaymentStore**
- Durable record keyed by requestID/paymentID:
  - requested amount, selected mint/unit, payload sent, status, timestamps,
  - offline/online acceptance mode,
  - later-finalization outcomes.

### 5.2 Components (network-side)
- BLE mesh transport (existing)
- Optional global transport (existing internet path)
- Optional “gateway nodes” with internet bridging mint calls and settlement gossip

---

## 6) Protocol & data model changes (code-facing)

### 6.1 AgentInfo additions (advertise terms)
Owned files: `bitchat/Models/AgentInfo.swift`, `bitchat/Protocols/Packets.swift`

Add `paymentTerms` to AgentInfo (v2 optional field; v1 clients ignore):

- `paymentRail`: `"none" | "cashu" | "x402"`
- `settlementMode`: `"online_required" | "offline_accepted"`
- `unit`: string (e.g., `"usd"`, `"usdc"`, `"sat"`)
- `priceModel` (MVP: per-request; later: per-token/tranches)
  - `pricePerRequest`: Int (in base units of `unit`)
  - later: `pricePerInputToken`, `pricePerOutputToken`, `minDeposit`, `granularity`
- `acceptedMints`: `[String]` (mint base URLs or IDs)
- `requestTTLSeconds`: Int (payment request validity)
- `offlineRiskPolicy` (only meaningful if `offline_accepted`)
  - `maxOfflinePerPeer`: Int
  - `maxOfflineOutstanding`: Int
  - `requireSettlementGossip`: Bool
  - `requireNotaryReceipts`: `{k: Int, n: Int}?`
- `requiresLocking` (active hardening field)
  - `none | p2pk`

Locking defaults:
- `offline_accepted` defaults to `p2pk` unless explicitly overridden.
- `online_required` defaults to `none`.
- Unknown/invalid values normalize to `none`.

Notes:
- Cashu terms: `acceptedMints`, optional offline acceptance, optional P2PK locking.
- x402 terms: `x402ChainID`, `x402TokenAddress`, `x402PayTo`, `x402GatewayURL`, `x402FacilitatorID`, `x402Scheme`, online-only settlement.

### 6.2 Packets

Owned file: `bitchat/Protocols/Packets.swift`

Add/extend:

**AgentResponsePacket**
- `paymentRequired: Bool`
- `paymentRequest: String?` (`creq:` for Cashu, `xreq:` for x402)
- `paymentError: String?` (invalid/expired/unreachable mint)

When `paymentRequest` is present, envelope fields can include:
- `requiresLocking`
- `lockPubkey`
- `lockSigFlag` (default `1`, SigAll)

Add new packets (recommended over slash-commands):

**AgentPaymentPayloadPacket**
- `requestID: String`
- `sessionID: String?`
- `rail: String` (e.g., `"cashu"` or `"x402"`)
- `payload: String` (serialized rail-specific payment payload envelope)
- `sentAt: UInt64`
- `clientNonce: String` (anti-replay signal)

Locking-compatible payload envelope fields:
- `proofs`
- `token` (required for `requiresLocking = p2pk`)
- `requiresLocking`
- `lockPubkey`

x402 payload envelope fields:
- `paymentID`, `requestID`
- `paymentData`, `payerAddress`
- `clientNonce`, `createdAtMs`

**AgentPaymentReceiptPacket** (provider → requester)
- `requestID: String`
- `sessionID: String?`
- `status: "accepted_offline" | "finalized_online" | "rejected"`
- `details: String?` (optional)
- `nullifiers: [String]?` (hashed)
- `notaryReceipts: [String]?` (4F)

Note: Payment packets bind to sessions when `sessionID` is present; otherwise they are bound only to `requestID`.

Optional packets for gateway mode:

**MintProxyRequestPacket**
- `proxyID: String` (unique)
- `mintURL: String`
- `method: "info" | "keysets" | "swap" | "checkstate" | "relock"`
- `body: String` (JSON)
- `sentAt: UInt64`

**MintProxyResponsePacket**
- `proxyID: String`
- `ok: Bool`
- `body: String?`
- `error: String?`

### 6.3 Settlement rooms (optional but recommended)
Define a room/topic name convention:

- Mesh: `#settle` or `#settle:<hash(mintURL||unit)>`
- Global: `#settle-global` (only if internet path exists)

Define message schema:

**SpendAnnounce**
- `mintHint`: String (optional; hashed recommended)
- `unit`: String (optional)
- `paymentID`: String (from payment request)
- `nullifiers: [String]` (hashed)
- `ts`: UInt64
- `sig`: String (sender signature; optional in MVP, required later)

**SpendConflict**
- `nullifier`: String
- `seenAt`: UInt64
- `evidence`: String? (optional)

Rules:
- Never include bearer proofs.
- Keep metadata minimal (prefer hashed mint hints and omit amounts).

---

## 7) Payment flows (by connectivity case)

### 7.1 MVP flow (per-request payment)

#### Case B (provider has internet): Strong finality path
1) Requester → Provider: `AgentRequest`
2) Provider → Requester: `AgentResponse(paymentRequired=true, paymentRequest=…)`
3) Requester → Provider: `AgentPaymentPayloadPacket(payload=…)`
4) Provider: validate payload; finalize immediately (swap to receive)
5) Provider → Requester: final response + `AgentPaymentReceipt(status=finalized_online)`

Provider MUST NOT release final output until swap succeeds.

#### Case A (both BLE-only): Risk-managed offline path
1) Same steps 1–3
2) Provider: validate payload offline (authenticity); record nullifiers; apply caps
3) Provider: optionally `SpendAnnounce` in mesh `#settle`
4) Provider → Requester: final response + `AgentPaymentReceipt(status=accepted_offline)`
5) Later: provider finalizes when any mint path exists; update local settlement ledger

Important: This is not perfect. It’s “cash acceptance with limits.”

#### Case C (payer has internet, provider does not): Safer offline acceptance path (implemented hardening)
- Provider requests P2PK locking in the payment request (`requiresLocking = p2pk`, `lockPubkey`, `lockSigFlag`).
- Payer relocks proofs to provider’s per-request key (direct path first, gateway relock fallback if direct relock unavailable).
- Provider accepts only if lock binding validates; otherwise fail-closed.
- Provider finalizes later when mint path is available.

#### Case D (gateway exists): Mesh-online finality path
- Provider sends swap/checkstate via MintProxy packets to an internet gateway node.
- Requester can also use gateway relock via `MintProxyMethod.relock` when direct relock path fails.

### 7.2 Implemented milestone: per-token pricing with tranches (streaming)
Instead of paying once, payer pays in chunks:
- Provider sends partial output up to N tokens
- Requests/collects next tranche
- Finalizes each tranche when possible

This improves:
- fairness under disconnects,
- reduces loss if payer vanishes mid-request,
- supports per-token price models.

### 7.3 Implemented milestone: “fair exchange” with encrypted release (no HTLC required)
Current flow improves fairness by:
- Provider sends ciphertext of final answer first
- Reveals decryption key after payment acceptance (online or offline-accepted)

This reduces “provider took payment and ghosted” without needing complex mint features.

---

## 8) Privacy & security design rules (implementation constraints)

### 8.1 Do not broadcast bearer proofs
- Proofs are bearer value and must never be posted in rooms or public channels.
- Payment payload is only sent directly to the intended provider (private / E2E where available).

### 8.2 Prefer ephemeral receiving keys
- Provider rotates receiving identity:
  - per-request key for payment locking conditions (implemented in `AgentPaymentLockKeyStore`)
  - reduces linkability across requests

### 8.3 Offline authenticity verification is required for offline acceptance
If offline mode is enabled, provider MUST:
- verify token authenticity offline if DLEQ data is available,
- reject unknown/unsupported formats.

### 8.4 Mint allowlisting (do not auto-trust mints)
Wallet must:
- maintain an allowlist of trusted mints
- require explicit user opt-in to add a new mint
- never auto-swap unknown-mint tokens

### 8.5 Anti-replay / idempotency
Provider must store:
- requestID → paymentID mapping
- nullifiers already accepted for that requestID
- reject duplicate payloads (same nullifiers) for new requestIDs

### 8.6 Offline risk policy (provider-configurable)
If `offline_accepted`:
- enforce caps per peer/time window
- enforce cap on outstanding unfinalized offline receipts
- optionally require settlement gossip presence for acceptance
- optionally require “notary receipts” (implemented in 4F)

---

## 9) Implementation plan (Work Packages & milestones)

### Milestone 4A — MVP: Per-request Cashu payments with online finality + offline caps
This is the first shippable slice.

#### P4-MARKET-1: Price + payment terms in AgentInfo
- Owned files: `AgentInfo.swift`, `Packets.swift`
- Add minimal `paymentTerms` fields (see §6.1 MVP subset)
- Done when: caller can filter agents by rail/price/mode locally.

#### P4-AUTH-1: Payment required response flow
- Owned files:
  - `ChatViewModel+AgentMeshPayments.swift` (new)
  - `Packets.swift`
- Provider sends `paymentRequired + paymentRequest`.
- Done when: unpaid requests stop at payment request step.
- Dependencies: P4-MARKET-1, P4-STORE-1
- Compatibility alignment: P2-PAY-1, P2-PAY-2, P2-PAY-3, P3-PAY-1

#### P4-CASHU-FOUNDATION-1: Cashu wallet + parsing
- Owned files:
  - `Services/CashuWalletService.swift` (new)
  - `Services/CashuModels.swift` (new)
- Requirements:
  - import/export tokens
  - proof selection for amount
  - encrypted storage at rest
- Done when: user can load balance and construct a payload.

#### P4-CASHU-MINT-1: Online mint client (direct internet)
- Owned file: `Services/CashuMintClient.swift` (new)
- Implement: mint info + swap (and optionally checkstate)
- Done when: provider can finalize payments online.

#### P4-FLOW-1: UX for payment request + pay action
- Owned file: `ChatViewModel+AgentMeshPayments.swift`
- Replace `/agentpay` with button-driven UX (keep command for dev).
- Done when: payer can pay from the chat UI.
- Dependencies: P3-PAY-1

#### P4-STORE-1: Payment store + anti-replay
- Owned file: `Services/AgentPaymentStore.swift` (new)
- Record request/payment state, nullifiers accepted, status.
- Done when: no double prompts; provider rejects replay.
- Dependencies: P2-PAY-2

#### P4-OFFLINE-1: Risk-managed offline acceptance
- Owned files:
  - `AgentPaymentBridge.swift` (new or expanded)
  - `AgentPaymentStore.swift`
- Implement:
  - offline caps
  - mark receipts as `accepted_offline`
  - queue for later finalization
- Done when: payments work BLE-only with explicit caps and labeling.

---

### Milestone 4B — Mesh + global “settlement rooms” (nullifier gossip)
Purpose: reduce casual double-spend success rate in connected components.
Status: implemented in-tree (Phase 4B baseline).

#### P4-SETTLE-ROOM-1: Settlement gossip service
- Owned file: `Services/AgentSettlementGossip.swift` (new)
- Create `SpendAnnounce` and `SpendConflict` messages.
- Maintain rolling seen cache (LRU / bloom filter).
- Status: implemented.
- Done when: providers can detect obvious same-proof reuse locally.

#### P4-SETTLE-ROOM-2: Optional global settle room bridging
- Only when internet layer exists.
- Ensure we only gossip hashed nullifiers (no proofs).
- Status: implemented (bridge path active when internet relay path is available).
- Done when: mesh and global converge when any gateway exists.

---

### Milestone 4C — Mint gateway proxy (internet via one node)
Purpose: achieve mint-backed finality even if provider/payer has no internet, but someone does.
Status: implemented in-tree (baseline execution + retry/dedupe cache path).

#### P4-GATEWAY-1: Mint proxy packets + service
- Owned files: `Packets.swift`, `Services/MintGatewayService.swift` (new)
- Provide idempotent proxying and retry handling for mint operations (`swap`/`checkstate`) plus relock fallback (`relock`).
- Status: implemented.
- Done when: mesh-only nodes can finalize via gateway.

#### P4-RESILIENCE-1: Retry safety and caching
- Add request IDs and dedupe logic for swap/checkstate/relock.
- Status: implemented (deterministic request IDs + transient failure cache policy hardening + regression tests).
- Done when: lossy mesh does not cause “lost settlement” states.

---

### Milestone 4D — Per-token pricing and tranche streaming
Purpose: better economics and less risk under disconnects.
Status: implemented in-tree (baseline per-token/tranche flow).

#### P4-MARKET-2: Per-token price fields + granularity
- Extend AgentInfo priceModel.
- Status: implemented (`priceModel`, `pricePerInputToken`, `pricePerOutputToken`, `minDeposit`, `granularityTokens`).
- Done when: agents advertise token pricing.

#### P4-STREAM-1: Tranche payment flow
- Provider emits partial output per tranche.
- Requester pays next tranche.
- Status: implemented (sequential payment requests + streaming pause/resume across tranche interstitials).
- Done when: stable streaming UX works offline and online.

---

### Milestone 4E — Fair exchange improvements (encrypted release)
Purpose: reduce “provider took payment but didn’t deliver.”
Status: implemented in-tree (baseline encrypted-offer + unlock flow).

#### P4-FAIR-1: Encrypt final output until payment accepted
- Provider sends ciphertext first
- Reveals key after `finalized_online` OR after offline acceptance policy is satisfied
- Status: implemented (`AgentFairExchangeService`, `afex1:` chunk flow, `fairUnlockKey` receipt binding, requester decrypt path).
- Done when: users experience “pay unlocks answer” semantics.

---

### Milestone 4F — Offline hardening (notary receipts + P2PK locking)
Purpose: make offline mode safer without pretending it’s perfect.

#### P4-NOTARY-1: Notary receipts (k-of-n)
- Define “notary-capable” nodes (opt-in; can be providers or designated nodes).
- Provider optionally requires k signatures over nullifiers.
- Status: implemented (opt-in notary nodes, request/attestation gossip, provider-side k-of-n enforcement for offline acceptance).
- Done when: double spend becomes significantly harder inside a connected mesh.

#### P4-P2PK-1: P2PK lock/relock hardening
- `requiresLocking` is advertised in payment terms (`none | p2pk`) with defaults by settlement mode.
- Requester relocks proofs to provider’s per-request lock pubkey before payload send.
- Direct mint relock is primary path; gateway relock (`MintProxyMethod.relock`) is fallback.
- Provider enforces fail-closed validation for lock-required requests and signs/finalizes with stored per-request lock secret.
- Status: implemented (`AgentPaymentLockKeyStore`, `CashuP2PKService`, `AgentPaymentBridge` relock/enforcement paths, `MintGatewayService` relock proxy handling).
- Done when: intercepted proofs cannot be reused for settlement without matching lock binding.

#### P4-REPUTATION-1: Reputation policy (deferred)
- Deferred pending additional privacy review and threat-modeling.
- Keep this out of runtime behavior until a dedicated privacy-first design pass is completed.
- Done when: a privacy-reviewed spec exists and is explicitly approved for implementation.

---

### Milestone 4G — Provider incentives (“capacity payments”) (optional, later)
Goal: encourage supply availability without sybil farming.

Principle: do not pay “interest for being online” without sybil resistance.

If implemented:
- Fund incentives from:
  - a small “network fee” on paid requests
  - or explicit subsidies
- Use sybil resistance:
  - stake/bond, proof-of-service, or rate-limited eligibility
- Pay based on:
  - successful fulfilled paid requests,
  - responsiveness/uptime,
  - quality signals,
  - and stake factor.

This milestone requires careful threat modeling and is not needed to ship paid requests.

---

## 10) Testing plan (must-have)

### Unit tests
- Token/payload decode/encode
- Proof selection for amounts
- Store idempotency: same payload not accepted twice
- Offline caps and rate windows

### Integration tests (simulated transports)
- Case A: both offline (BLE-only)
  - accept offline, record nullifiers, gossip, produce receipt
- Case B: provider online
  - swap finalization gating (no output before finalize)
- Case D: gateway proxy
  - swap via proxy + retries under packet loss

### Adversarial tests
- Double-spend attempt:
  - same payload to two providers in same mesh component → second detects via gossip OR later fails finalization
- Replay:
  - resend payload for a different requestID → provider rejects
- Partition:
  - accept offline in partition A and B; later only one finalizes; ensure app handles “finalization failure” cleanly
- Spam:
  - settlement room spam; ensure bounded memory and rate limiting

---

## 11) UX requirements (MVP + later)

### MVP UI
- In chat:
  - “Payment required” message with amount/unit/mint hint/expiry
  - “Pay” button
  - “Offline acceptance” warning if settlementMode is offline_accepted
- Wallet:
  - view balance per mint/unit
  - import/export token (for MVP onboarding)
  - mint allowlist management

### Later UI
- streaming progress (“paid tranche 2/5”)
- show finalization status and any disputes
- provider dashboard for caps, modes, and receipts

---

## 12) Key decisions (implemented)

1) **Cashu stack**
   - `cdk-swift` (`CashuDevKit`) integrated for lock/relock/signing paths.

2) **Payment payload encoding**
   - Request/response uses JSON envelopes over packet payload fields.
   - Lock-required payloads also include `token`, `requiresLocking`, and `lockPubkey`.

3) **Default provider locking mode**
   - `offline_accepted` defaults to `requiresLocking = p2pk`.
   - `online_required` defaults to `requiresLocking = none`.

4) **Connectivity preference for locking**
   - Direct mint relock first.
   - Mesh gateway relock fallback (`MintProxyMethod.relock`) when direct path is unavailable.

5) **Trust/reputation and incentives**
   - Deferred by design for privacy-first scope control.

---

## 13) Done definition (Phase 4 complete)

Phase 4 is “done” when:

- Paid requests work in all connectivity cases with explicit modes:
  - Online finality with gating
  - Offline acceptance with caps + later finalization
- Users can pay without manual commands.
- Providers can set price and enforce payment gating.
- No bearer proofs are ever posted to rooms.
- The system is robust to replay, basic double-spend attempts, and lossy transports.
- Remaining later milestones (reputation policy and incentives) are deferred by design unless explicitly re-prioritized.

---
