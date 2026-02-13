# Agent Mesh Setup (Local Testing)

Repeatable checklist for local testing on macOS/iOS devices.

Beta readiness checklist:
- `docs/BETA_CHECKLIST.md`

## Prereqs
- Two devices recommended for end-to-end mesh tests.
- Bluetooth enabled on both devices.
- For payment tests, preload requester wallet with a valid Cashu token.
- For x402 tests, configure a thirdweb client ID in Wallet settings and run the local gateway with x402 endpoints enabled.
- For macOS payment locking tests, macOS 14.5+ is required (CashuDevKit artifacts).

## Build and Run (macOS)
1. Open project:
   - `open /Users/kylewalsh/github-local/bitchat/bitchat.xcodeproj`
2. Select scheme:
   - `bitchat (macOS)`
3. Run (`Cmd+R`).

## Running Tests (SwiftPM)
Note: `swift test` can fail if your `PATH` prefers non-Apple toolchains (for example Conda’s `ld`),
which can produce an error like:
- `ld: unknown option: -no_warn_duplicate_libraries`

Use the blessed test entrypoint:
- `scripts/agent_mesh_test.sh`

Examples:
- `scripts/agent_mesh_test.sh`
- `scripts/agent_mesh_test.sh --filter AgentMeshPacketsTests`

## Baseline Agent Flow
### Provider device
- `/agentset general local 80`
- `/agenton`
- `/agentconfig`

### Requester device
- `/agent general hello`

Expected:
- request and response appear in a private DM thread with the agent.

## Tiered Quote Routing Checks (Phase 7 Complete)
1. Configure two or more providers with per-request payment terms enabled (same role, different `price per request` if desired).
2. On requester, run `/agent general quote routing test`.
3. Wait for quote list output and choose an option:
   - tap an option in the quote card, or
   - `/agentchoose <quoteID> <optionIndex>`
4. In requester Agent Preferences, set auto-pick policy (`cheapest`, `fastest`, or `best quality <= budget`) and repeat step 2.
5. On provider, adjust quote tier waits/discounts in Agent Settings (`Payments -> Quote tiers`) and repeat step 2.

Expected:
- requester receives a quote list with provider name, quality, wait tier, and estimated price.
- selecting an option (tap or command) sends exactly one quote-bound request (`quoteID` + `quoteOptionID`).
- for non-immediate tiers, request send is delayed locally by the quoted wait window before normal payment/runtime flow continues.
- with auto-pick enabled, requester dispatches immediately after quote collection closes and uses the selected policy consistently.
- unchosen quotes expire automatically and any stashed draft attachments are restored to the composer context.

## Streaming and Reliability Checks
1. On provider, keep agent enabled.
2. On requester, run `/agentstream on`.
3. Send a longer prompt (`/agent general write a long answer about ...`).
4. Temporarily move provider out of range, then back in range.

Expected:
- partial response rendering during stream.
- stalled stream triggers retry behavior.
- final response lands when peer is reachable again or timeout/error appears cleanly.

## Payment Interstitial Checks (Phase 4A Implemented)
### 1) Configure provider payment terms
Use Agent Settings UI on provider:
- Enable "Require payment before response".
- Set settlement mode (`online_required` or `offline_accepted`).
- Set pricing mode:
  - per-request: `unit` + `price per request`
  - per-token: `price per output token` (optional input token price), `min deposit`, `tranche token granularity`
- Set `accepted mints` and `request TTL seconds`.
- Confirm via `/agentconfig` that payments are shown.

### 2) Prepare requester wallet
- `/agentwallet` (check summary)
- `/agentwallet import <cashu_token>`
- `/agentwallet balance`

### 3) Trigger payment-required flow
- `/agent general paid prompt test`

Expected:
- requester receives payment interstitial message with request ID.
- message includes payment details and pay action path (`/agentpay <requestID>`).

### 4) Pay and resume
- `/agentpay <requestID>`

Expected:
- requester sees "payment sent; waiting for receipt".
- provider emits receipt (`accepted_offline`, `finalized_online`, or `rejected`).
- response flow resumes only after accepted receipt.

### 5) Expiry behavior
- set a short `request TTL seconds` on provider (for example `5`).
- wait past expiry before paying.

Expected:
- requester sees "payment request expired".
- stale payment is not accepted.

## X402 Multi-Rail Checks (Phase 4G Baseline)
### 1) Start gateway with x402 endpoints
- `python3 scripts/agent_gateway_proxy.py`

Optional upstream mode (instead of default mock):
- `export AGENT_X402_MODE=upstream`
- `export AGENT_X402_PREPARE_URL=https://...`
- `export AGENT_X402_SETTLE_URL=https://...`
- `export AGENT_X402_UPSTREAM_TOKEN=...`

### 2) Configure provider for x402
1. Open Settings -> Agents -> Enable provider mode (wizard).
2. In Payments step:
   - Rail: `x402`
   - Chain ID: e.g. `8453`
   - Token address: ERC-20 address
   - Pay-to address: provider receiving address
   - Gateway URL: e.g. `http://127.0.0.1:8080`
3. Finish wizard and verify provider is advertising.

### 3) Configure requester for x402
1. Open Settings -> Agents -> Requester preferences.
2. Enable `x402 payments` and set preferred rail to `x402`.
3. Open Wallet -> x402 Guest Wallet:
   - set thirdweb client ID
   - tap `Connect guest`

### 4) Execute paid request
1. Requester: `/agent <role> <prompt>`.
2. From payment interstitial, tap `Pay now`.

Expected:
- payment interstitial shows rail context (`Gateway`, `Chain`, `Token`, `Pay to`).
- requester emits `AgentPaymentPayloadPacket` with `rail=x402` and `xpay:` payload.
- provider settles through `POST /x402/settle` and returns `finalized_online`.

### 5) Gating behavior
1. Disable requester x402 preference in settings.
2. Retry a request where only x402 providers are available.

Expected:
- requester does not auto-select x402-only providers while x402 is disabled.
- if an x402 `paymentRequired` packet is received while disabled, requester shows a clear disabled-rail message.

## P2PK Locking Checks (Phase 4 Hardening)
### 1) Direct relock path
1. Provider: set settlement mode to `offline_accepted` and keep locking set to `p2pk` in Agent Settings.
2. Requester: ensure direct mint path is reachable for wallet/mint client.
3. Send a paid request and run `/agentpay <requestID>`.

Expected:
- payment interstitial includes lock marker (`lock p2pk`).
- requester relocks proofs before payload send.
- provider rejects payload if lock fields are missing or pubkey does not match the stored request binding.
- valid locked payload is accepted (`accepted_offline` or `finalized_online` depending on mint reachability).

### 2) Gateway relock fallback path
1. Keep provider locking set to `p2pk`.
2. Force direct requester->mint relock path failure (temporary network block for requester).
3. Ensure at least one mesh peer has gateway + internet mint access.
4. Retry `/agentpay <requestID>`.

Expected:
- requester falls back to mint proxy `relock` method via gateway.
- success response returns relocked proofs/token and payment payload is sent once.
- transient relock proxy failures are not cached; retry with the same `proxyID` can recover.
- if both direct and gateway relock fail, `/agentpay` surfaces an error and prompt remains pending.

## Per-Token Tranche Checks (Phase 4D)
### 1) Configure per-token pricing
1. On provider, set pricing mode to `per token`.
2. Set:
   - `price per output token` > 0
   - optional `price per input token`
   - optional `minimum first-tranche deposit`
   - `tranche token granularity` (for example `6`)

### 2) Trigger long request
1. On requester, send a long agent prompt (`/agent general <long text>`).

Expected:
- requester receives payment interstitial for tranche `1/N`.
- paying tranche `1/N` yields partial streamed output, then a new payment interstitial for tranche `2/N`.
- stream does not time out while waiting at payment interstitial.

### 3) Complete all tranches
1. Repeat `/agentpay <requestID>` until no further tranche prompt appears.

Expected:
- each accepted payment advances exactly one tranche.
- final emitted chunk is marked final only after the last tranche is paid.
- requester sees full assembled response; provider session shows completed response.

## Fair Exchange Checks (Phase 4E)
### 1) Configure per-request paid flow
1. On provider, set pricing mode to `per request`.
2. Ensure payments are enabled and mint is reachable (`online_required` preferred for baseline check).

### 2) Trigger encrypted-offer pre-release
1. On requester, send `/agent general <paid prompt>`.

Expected:
- requester sees payment-required interstitial.
- requester sees an encrypted-lock indicator (`encrypted response ready. pay to unlock.`) before paying.
- provider emits fair-exchange offer chunks (`afex1:` payload segments) on the wire.

### 3) Pay and verify unlock
1. On requester, run `/agentpay <requestID>`.

Expected:
- provider receipt status is accepted/finalized and includes fair unlock token (`fairUnlockKey`).
- requester decrypts and renders final plaintext response from offer + unlock.
- compatibility fallback still returns normal post-payment response semantics for legacy clients.

### 4) Reordering resilience
1. Introduce packet reordering/drop in a test harness so receipt can arrive before final offer chunks.

Expected:
- requester still unlocks once both receipt unlock token and full offer arrive.
- no duplicate final response rows are produced for the same `requestID`.

## Payment Filter Check
- `/agentfilter cashu sat any online_required`
- `/agentfilter` (inspect active filter)
- `/agentfilter clear`

Expected:
- routing selection honors filter when enabled.
- clear resets to unrestricted selection.

## Session + Memory Checks (Phase 6)
### 1) Session lifecycle commands
1. Run `/agent general first turn`.
2. Run `/agentsession list`.
3. Run `/agentsession new`.
4. Run `/agentsession list` again.

Expected:
- each new session has a different `sessionID` alias/thread.
- session history entries are persisted and listed by recency.

### 2) Session resume seeding
1. From `/agentsession list`, take a prior session ID prefix.
2. Run `/agentsession resume <prefix>`.
3. Send a follow-up message in the resumed thread.

Expected:
- a brand-new ephemeral session is created.
- previous turns are injected on the first resumed request only.

### 3) Memory editor and attachment
1. Open Agent Settings -> Memory.
2. Edit `MEMORY.md`, save, and attach it.
3. Send `/agent general use my memory context`.

Expected:
- request includes local memory context prefixing the outgoing prompt.
- memory content does not broadcast separately; only the request payload changes.

### 4) Auto-recall
1. In Memory settings, add a daily note with a unique keyword.
2. Enable auto-recall.
3. Send `/agent general <keyword question>`.

Expected:
- keyword-matching snippet is auto-injected into the outgoing prompt context.
- disabling auto-recall stops automatic snippet injection.

### 5) Session payment state UI
1. Trigger a payment-required request and pay it.
2. Observe Sessions sidebar row for that conversation.

Expected:
- session row state updates through payment lifecycle labels (`paid`, `offline`, `finalized`, `failed` as applicable).

### 6) One-tap wipe
1. In Agent Settings -> Memory, tap `Wipe memory + sessions`.

Expected:
- `MEMORY.md` and daily logs are removed.
- session history is cleared and active agent session context is reset.

## Gateway Runtime (Optional)
### OpenAI proxy
- `export OPENAI_API_KEY=sk-...`
- `export AGENT_GATEWAY_MODEL=gpt-4.1-mini`
- `python3 scripts/agent_gateway_proxy.py`
- `/agentruntime gateway`
- `/agentgateway http://127.0.0.1:8080/agent/run`

### Gateway catalog
The gateway can expose a local model catalog for UI selection:
- `curl http://127.0.0.1:8080/agent/catalog`

Expected shape:
```json
{
  "providers": ["ollama"],
  "models": [
    {
      "id": "llama3.1:8b",
      "provider": "ollama",
      "name": "llama3.1:8b",
      "sizeBytes": 0,
      "quant": "Q4_K_M",
      "contextTokens": null,
      "qualityScore": null,
      "modelHash": "ollama:sha256:<64-hex>"
    }
  ]
}
```

Notes:
- Set `AGENT_GATEWAY_PROVIDER=ollama` to query local Ollama tags (requires Ollama running on `OLLAMA_BASE_URL`, default `http://127.0.0.1:11434`).
- OpenAI/Gemini providers return a minimal catalog and typically omit `modelHash`.
- X402 endpoints are also served by this process:
  - `POST /x402/prepare` (requester-side payment preparation; mock by default)
  - `POST /x402/settle` (provider-side settlement check/finalize)

### Gemini proxy
- `export AGENT_GATEWAY_PROVIDER=gemini`
- `export GEMINI_API_KEY=your_key`
- `export AGENT_GATEWAY_MODEL=gemini-3-pro-image-preview`
- `python3 scripts/agent_gateway_proxy.py`

If provider is iOS, bind proxy to LAN and use Mac LAN IP.

## Troubleshooting
- No peers: verify Bluetooth and both apps running.
- Agent not selected: ensure provider ran `/agenton` and role matches.
- Payment failures: check wallet balance, mint URL allowlist, and TTL expiry.
- No response after payment: inspect receipt status in chat/system messages.

## Reset / Disable
- `/agentoff`
- `/agentfilter clear`
- `/agentconfig`

## Notes
- Request/response TLV fields are 255-byte bounded.
- Payment/mint proxy packets use TLV16 framing.
- Payment packet replay/idempotency behavior is covered by `AgentPaymentStore` tests.

## Settlement Gossip Checks (Phase 4B)
### 1) Mesh `#settle` conflict propagation
1. Bring up three devices in one mesh component:
   - `provider-A` (payments enabled)
   - `provider-B` (payments enabled)
   - `payer`
2. Trigger a paid request to `provider-A` and complete payment once.
3. Reuse the same payload material against `provider-B` (test harness/replay path).

Expected:
- `provider-B` rejects before runtime execution with a nullifier conflict reason.
- conflict signal is broadcast as settlement gossip (`SpendConflict`), not proofs.

### 2) Duplicate settlement message handling
1. Re-broadcast the same settlement payload message multiple times from a peer.

Expected:
- duplicates are deduped and ignored.
- no timeline spam in normal public chat views.

### 3) Optional global convergence (`#settle-global`)
1. Ensure at least one node has active internet relay path.
2. Produce settlement gossip in mesh only (`#settle`).
3. Observe global relay subscribers on another connected component.

Expected:
- mesh event is bridged to `#settle-global`.
- downstream node re-injects to local mesh when appropriate.

## Notary Hardening Checks (Phase 4F)
### 1) Notary request/attestation propagation
1. Enable `Act as notary signer` on one device (`notary-node`).
2. From another mesh node, broadcast a `notary1:` request (or trigger an offline acceptance path with notary requirement).
3. Observe mesh public payload relay.

Expected:
- `notary-node` emits an attestation (`notary_attest`) with `anr1:` receipt.
- attestation is forwarded over mesh and optionally bridged to `#settle-global` when relay path exists.

### 2) Offline k-of-n enforcement
1. Provider: set settlement mode to `offline_accepted` and set `Offline notary receipts required` to `k > 0`.
2. Force mint unreachable for provider path (local network block or unreachable mint URL).
3. Pay request once with fewer than `k` active notary signers.
4. Repeat with at least `k` active notary signers.

Expected:
- first attempt is rejected with notary threshold details (for example `offline notary receipts 1/2`).
- second attempt is accepted as `accepted_offline` and receipt includes `notaryReceipt` entries.
- no bearer proofs are broadcast in public rooms.

## Gateway Checks (Phase 4C)
### Mint proxy retry/idempotency
1. Bring up three nodes:
   - `requester` with payments enabled
   - `provider` configured for `online_required`
   - `gateway` node with internet path to the configured mint
2. Ensure requester/provider can reach gateway over mesh.
3. Trigger a paid request and pay it (`/agentpay <requestID>`).
4. During settlement, induce one transient failure on first gateway attempt (drop first response or return temporary error), then allow the next attempt.
5. Re-send the same `proxyID` request from test harness once more.

Expected:
- requester retries to the next eligible gateway peer or attempt window.
- provider receives a successful mint proxy response and emits `finalized_online`.
- duplicate `proxyID` returns the cached response path; mint operation is not re-executed.
