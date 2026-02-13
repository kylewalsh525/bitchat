# Agent Mesh Protocol

This document describes protocol-level behavior for agent discovery, request/response flows, streaming, and payment-compatible payloads.

## Compatibility and Versioning
- `agentInfo` remains an optional announce TLV (`0x05`), so legacy clients can ignore it safely.
- Unknown TLVs are skipped by tolerant decoders.
- `AgentInfo` uses explicit versioning:
  - `v1` (`0x01`): role/model/quality/hash only
  - `v2` (`0x02`): v1 fields plus optional `paymentTerms`
- The runtime default version is `AgentMeshConstants.agentInfoVersion = v2`.

## Announcement TLV: `agentInfo` (`0x05`)
### Purpose
Advertise agent capability metadata during mesh discovery.

### `AgentInfo v1` fields
- `role`
- `modelId`
- `qualityScore`
- `modelHash` (optional)

`modelHash` format and meaning:
- Preferred format: `ollama:sha256:<64-hex>` (artifact digest for Ollama model pulls).
- Also accepted: `sha256:<64-hex>` (generic artifact digest).
- This is a **self-attested claim** about the model artifact, not a proof of inference/runtime behavior.
- Because mesh announce packets are signed and verification is enforced, the claim is identity-bound to the advertising peer (but still not verifiable as a “proof of compute”).

### `AgentInfo v2` extension: `paymentTerms` (optional)
`paymentTerms` fields:
- `paymentRail` (`none | cashu | x402`)
- `settlementMode` (`online_required | offline_accepted`)
- `unit` (for example `sat`, `usd`, `usdc`)
- `priceModel` (`per_request | per_token`)
- `pricePerRequest`
- `pricePerInputToken` (optional)
- `pricePerOutputToken` (optional)
- `minDeposit` (optional)
- `granularityTokens` (optional)
- `acceptedMints`
- `requestTTLSeconds`
- `requiresLocking` (`none | p2pk`)
- `x402ChainID` (optional; required for `paymentRail=x402`)
- `x402TokenAddress` (optional; required for `paymentRail=x402`)
- `x402PayTo` (optional; required for `paymentRail=x402`)
- `x402GatewayURL` (optional; required for `paymentRail=x402`)
- `x402FacilitatorID` (optional; defaults to `thirdweb`)
- `x402Scheme` (optional; currently `exact`)

`requiresLocking` defaults:
- `offline_accepted` defaults to `p2pk` unless explicitly overridden.
- `online_required` defaults to `none`.
- unknown values normalize to `none`.

Rail behavior:
- `cashu`: supports `online_required` and `offline_accepted`.
- `x402`: normalized to `online_required` + `per_request`; offline acceptance is unsupported.

If the encoded v2 extension cannot fit within announce constraints, encoder behavior falls back to v1.

## Noise Payload Types
Agent mesh payloads inside `noiseEncrypted`:
- `0x20` = `agentRequest`
- `0x21` = `agentResponse`
- `0x22` = `agentResponseChunk`
- `0x23` = `agentQuoteRequest`
- `0x24` = `agentPaymentPayload`
- `0x25` = `agentPaymentReceipt`
- `0x26` = `mintProxyRequest`
- `0x27` = `mintProxyResponse`
- `0x28` = `agentQuoteResponse`

## Agent Request Packet (`AgentRequestPacket`)
TLV fields:
- `requestID` (`0x00`) string
- `role` (`0x01`) string
- `prompt` (`0x02`) string
- `sessionID` (`0x03`) string optional
- `attachmentCount` (`0x04`) uint8 optional
- `senderAlias` (`0x05`) string optional
- `createdAtMs` (`0x06`) uint64 optional
- `ttlMs` (`0x07`) uint32 optional
- `quoteID` (`0x08`) string optional
- `quoteOptionID` (`0x09`) string optional

`quoteID` + `quoteOptionID` bind a selected quote tier to the request when quote-routing is used.

## Quote Request Packet (`AgentQuoteRequestPacket`)
Uses TLV16 framing.

Fields:
- `quoteID` (`0x00`) string
- `role` (`0x01`) string
- `prompt` (`0x02`) string
- `estimatedInputTokens` (`0x03`) uint32 optional
- `estimatedOutputTokens` (`0x04`) uint32 optional
- `sentAt` (`0x05`) uint64
- `maxOptions` (`0x06`) uint8

## Quote Response Packet (`AgentQuoteResponsePacket`)
Uses TLV16 framing.

Fields:
- `quoteID` (`0x00`) string
- `role` (`0x01`) string
- `optionsJSON` (`0x02`) JSON array of quote options
- `expiresAt` (`0x03`) uint64
- `error` (`0x04`) string optional

Quote option schema (per item):
- `optionID`
- `label`
- `waitSeconds`
- `discountBps`
- `estimatedPrice`
- `paymentRail`
- `unit`
- `settlementMode`
- `acceptedMints`
- `requestTTLSeconds`
- `chainID` (optional)
- `tokenAddress` (optional)
- `qualityScore`
- `modelId`
- `modelHash`
- `requiresLocking`

Behavior notes:
- Quote selection is requester-driven (`/agentchoose` command path in current UX).
- Non-zero `waitSeconds` tiers are expected to enforce delayed dispatch semantics before acceptance.
- Payment request generation still occurs only after a quote-selected request is sent.

## Agent Response Packet (`AgentResponsePacket`)
TLV fields:
- `requestID` (`0x00`) string
- `content` (`0x01`) string
- `isError` (`0x02`) bool
- `sessionID` (`0x03`) string optional
- `chunkIndex` (`0x04`) uint16 optional
- `chunkTotal` (`0x05`) uint16 optional
- `paymentRequired` (`0x06`) bool optional
- `paymentRequest` (`0x07`) string optional
- `paymentError` (`0x08`) string optional

`paymentRequired=true` marks a payment interstitial and is used by streaming and runtime gating.
For per-token pricing/tranche flow, multiple `paymentRequired` interstitials may occur within one `requestID`.

## Streaming Packet (`AgentResponseChunkPacket`)
TLV fields:
- `requestID` (`0x00`) string
- `content` (`0x01`) string
- `isError` (`0x02`) bool
- `sessionID` (`0x03`) string optional
- `index` (`0x04`) uint16
- `isFinal` (`0x05`) bool

Phase 4E fair-exchange offer chunks use the same packet type with content prefix:
- `afex1:` (chunk payload contains serialized encrypted-offer segment data)

## Payment Payload Packet (`AgentPaymentPayloadPacket`)
Uses TLV16 framing to support larger payload sizes.

Fields:
- `requestID` (`0x00`) string
- `sessionID` (`0x01`) string optional
- `rail` (`0x02`) string (`cashu | x402`)
- `payload` (`0x03`) string (serialized payment payload)
- `sentAt` (`0x04`) uint64
- `clientNonce` (`0x05`) string

Cashu payment request envelopes (`creq:` payload in `paymentRequest`) can include tranche metadata for per-token mode:
- `pricingModel`
- `trancheIndex`
- `trancheCount`
- `trancheTokenCount`
- `outputTokenPrice`
- `inputTokenPrice`
- `minimumDeposit`
- `requiresLocking`
- `lockPubkey`
- `lockSigFlag` (default `1`, SigAll)

Requester payment payload envelopes (`cpay:` payload in `AgentPaymentPayloadPacket.payload`) can include:
- `token` (required when `requiresLocking == p2pk`)
- `requiresLocking`
- `lockPubkey`

X402 payment request envelope (`xreq:` payload in `paymentRequest`) fields:
- `version`
- `paymentID`
- `requestID`
- `amount`
- `unit`
- `chainID`
- `tokenAddress`
- `payTo`
- `gatewayURL`
- `expiresAtMs`
- `sessionID` (optional)
- `scheme`
- `facilitatorID` (optional)

X402 payment payload envelope (`xpay:` payload in `AgentPaymentPayloadPacket.payload`) fields:
- `paymentID`
- `requestID`
- `paymentData`
- `payerAddress`
- `clientNonce`
- `createdAtMs`

X402 payment rules:
- requester side payment is delegated to a facilitator wallet bridge (guest wallet capable).
- provider settlement is online-only via `POST /x402/settle` against the configured gateway URL.
- idempotency/replay protection uses `requestID + paymentID + H(paymentData)`.

## Payment Receipt Packet (`AgentPaymentReceiptPacket`)
Uses TLV16 framing.

Fields:
- `requestID` (`0x00`) string
- `sessionID` (`0x01`) string optional
- `status` (`0x02`) enum: `accepted_offline | finalized_online | rejected`
- `details` (`0x03`) string optional
- `nullifier` (`0x04`) repeated string
- `notaryReceipt` (`0x05`) repeated string
- `paymentID` (`0x06`) string optional
- `fairUnlockKey` (`0x07`) string optional (`aunlock1:` payload)

Payment packets bind to sessions when `sessionID` is present; otherwise binding is only by `requestID`.
Receipts may include `paymentID` to disambiguate multi-tranche ordering for the same `requestID`.
When provider offline-notary policy is enabled, `notaryReceipt` entries carry k-of-n attestations that gate `accepted_offline` status.
When fair exchange is active, receipts can include `fairUnlockKey` so requester can decrypt a previously received encrypted offer.

## Fair Exchange Envelopes (Phase 4E)
These are encoded into string payloads (not new Noise payload types):
- `aoffer1:` prefix for encrypted response offers (sent via `AgentResponseChunkPacket` content segments prefixed with `afex1:`).
- `aunlock1:` prefix for unlock token material (sent in `AgentPaymentReceiptPacket.fairUnlockKey`).

Binding rules:
- Offer + unlock must match on `requestID`, `paymentID`, and `sessionID` (when present).
- Requester must verify offer commitment before decrypting.

## Mint Proxy Packets
### `MintProxyRequestPacket` (TLV16)
- `proxyID` (`0x00`) string
- `mintURL` (`0x01`) string
- `method` (`0x02`) enum: `info | keysets | swap | checkstate | relock`
- `body` (`0x03`) string
- `sentAt` (`0x04`) uint64

### `MintProxyResponsePacket` (TLV16)
- `proxyID` (`0x00`) string
- `ok` (`0x01`) bool
- `body` (`0x02`) string optional
- `error` (`0x03`) string optional

Note: Mint proxy packet schema and runtime request/response handling are active in current flow (including direct-to-proxy fallback, relock gateway fallback, and `proxyID` idempotency semantics).

## Settlement Gossip Payload (`settle1:`)
Settlement gossip is room content (not a Noise payload type) used for nullifier conflict signaling.

Envelope prefix:
- `settle1:`

Envelope fields:
- `version` (currently `1`)
- `type` (`spend_announce | spend_conflict`)
- `eventID` (stable hash for dedupe)
- `room` (`#settle` or `#settle-global`)

`spend_announce` fields:
- `mintHint` (hashed mint+unit hint)
- `unit`
- `paymentID`
- `nullifiers` (hashed identifiers only)
- `ts`

`spend_conflict` fields:
- `nullifier`
- `seenAt`
- `evidence` (optional reason string)

Forwarding behavior:
- Mesh ingest can request global forwarding.
- Global ingest can request mesh forwarding.
- Duplicate and rate-limited events are ignored.

## Notary Gossip Payload (`notary1:`)
Notary gossip is room content (not a Noise payload type) used for optional k-of-n offline acceptance witnesses.

Envelope prefix:
- `notary1:`

Envelope fields:
- `version` (currently `1`)
- `type` (`notary_request | notary_attest`)
- `eventID` (stable hash for dedupe)
- `room` (`#settle` or `#settle-global`)

`notary_request` fields:
- `requestID`
- `paymentID`
- `mintHint`
- `unit`
- `nullifierDigest`
- `nullifiers`
- `requesterPeerID`
- `ts`

`notary_attest` fields:
- request context fields above
- `receipt` (`anr1:` encoded receipt payload)

`anr1:` receipt payload fields:
- `requestID`, `paymentID`, `mintHint`, `unit`, `nullifierDigest`, `nullifierCount`
- `notaryPeerID`, `notarySigningKey`, `issuedAtMs`, `signature`

Forwarding behavior:
- Mesh ingest can request global forwarding.
- Global ingest can request mesh forwarding.
- Duplicate events are ignored; receipt selection dedupes by signer identity.

## File Transfer Context for Agent Attachments
Agent attachments are sent as `BitchatFilePacket` using:
- `contextID = sessionID`
- `content = file data`

Attachment matching order:
1. `sessionID` (`contextID`)
2. sender peer fallback

## Limits and Safety Rules
- Request/response string TLVs are capped to 255 bytes per field.
- Payment and mint proxy packets use TLV16 framing and can exceed 255-byte single-field limits.
- Bearer payment proofs must only travel in direct encrypted agent payment payloads.
- Never broadcast bearer proofs in rooms or public channels.
- P2PK lock-required payments are fail-closed in provider evaluation: missing/mismatched lock binding rejects the payload.
- X402 rails are online-only and depend on gateway/facilitator availability.
- `modelHash` and payment rail claims are identity-bound but self-attested; they are not proof-of-compute guarantees.
- Settlement-room nullifier gossip is active for Phase 4B (`#settle` mesh, optional `#settle-global` bridge when internet relay path exists).
- Settlement gossip carries hashed nullifier signals only; proofs/tokens are out of scope for room broadcast.
