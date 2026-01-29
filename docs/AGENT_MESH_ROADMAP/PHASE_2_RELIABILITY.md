# Phase 2 - Request Lifecycle Reliability

Goal: Add TTL, idempotency, and retry behavior for intermittent mesh links.

## Work Packages
### P2-PROTOCOL-1: TTL and createdAt TLVs
- Goal: Allow expiry of stale requests.
- Owned files: `bitchat/Protocols/Packets.swift`,
  `bitchat/Protocols/BitchatProtocol.swift`
- Interfaces:
  - `AgentRequestPacket` adds TLVs:
    - `createdAtMs` (UInt64, type 0x03)
    - `ttlMs` (UInt32, type 0x04)
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
