# Phase 2 - Request Lifecycle Reliability

Goal: Add TTL, idempotency, and retry behavior for intermittent mesh links.

Status: Complete
- Added request TTL + createdAt TLVs for expiry.
- Added retry queue with reconnect flushing and max retries.
- Added response idempotency cache + resend.
- Added deterministic unit tests for TTL expiry, retry behavior, idempotency resend, and payment prompt expiry.

## Work Packages
### P2-PROTOCOL-1: TTL and createdAt TLVs
- Goal: Allow expiry of stale requests.
- Owned files: `bitchat/Protocols/Packets.swift`,
  `bitchat/Protocols/BitchatProtocol.swift`
- Interfaces:
  - `AgentRequestPacket` adds TLVs:
    - `createdAtMs` (UInt64, type 0x06)
    - `ttlMs` (UInt32, type 0x07)
- Dependencies: P0-SPEC-1
- Done when: encoder/decoder supports TTL and ignores unknown TLVs.

### P2-SENDER-1: Pending request expiry
- Goal: Time out requests locally and surface errors.
- Owned files: `bitchat/ViewModels/Extensions/ChatViewModel+AgentMeshRequests.swift` (new)
- Interfaces:
  - `AgentRequestContext { requestID, peerID, deadline, retries }`
  - Timer-based expiry that emits a system error message
- Dependencies: P2-PROTOCOL-1
- Done when: expired requests are removed and user is notified.

### P2-RETRY-1: Retry queue on reconnect
- Goal: Retry a failed request when peer becomes reachable again.
- Owned files: `bitchat/Services/AgentRetryQueue.swift` (new),
  `bitchat/ViewModels/ChatViewModel.swift` (hook only)
- Interfaces:
  - `enqueue(request, targetPeerID, attemptsLeft)`
  - `retryOnReachable(peerID)`
- Dependencies: P2-SENDER-1
- Done when: a disconnected peer triggers retries up to max attempts.

### P2-IDEMPOTENCY-1: Response cache and resend
- Goal: Prevent duplicate work when retries are in flight.
- Owned files: `bitchat/ViewModels/Extensions/ChatViewModel+AgentMeshRequests.swift`
- Interfaces:
  - `cacheAgentResponseIfNeeded`
  - `cachedAgentResponse(for:)`
- Dependencies: P2-RETRY-1
- Done when: duplicate request IDs resend cached responses.

### P2-PAY-1: Payment request TTL + expiry
- Goal: Enforce payment request expiry using `requestTTLSeconds`.
- Owned files: `bitchat/ViewModels/Extensions/ChatViewModel+AgentMeshPayments.swift`
- Interfaces:
  - Clear pending payment state on expiry.
  - Surface “payment expired” error for the request.
- Dependencies: P4-MARKET-1
- Delivery note: co-deliver with Phase 4A payment request handling.
- Done when: expired payment requests are rejected and removed locally.

### P2-PAY-2: Payment idempotency + replay controls
- Goal: Prevent replay or duplicate payment acceptance.
- Owned files: `bitchat/Services/AgentPaymentStore.swift`
- Interfaces:
  - Dedupe by `requestID + paymentID + nullifiers`.
  - Reject payloads reused across different requestIDs.
- Dependencies: P4-STORE-1
- Delivery note: co-deliver with Phase 4A payment store rollout.
- Done when: duplicate payloads are rejected deterministically.

### P2-PAY-3: Retry policy for payment packets
- Goal: Define retry behavior for payment payloads and receipts.
- Owned files: `bitchat/ViewModels/Extensions/ChatViewModel+AgentMeshPayments.swift`
- Interfaces:
  - Payment payloads are never auto-resent.
  - Receipts may be resent idempotently on reconnect.
- Dependencies: P2-PAY-2
- Done when: payment retries follow strict idempotency rules.
