# Phase 5 - Trust and Quality

Goal: Make agent selection rely on verifiable claims, not self-declared scores.

Status: Deferred
Note: This phase is intentionally out-of-scope right now. We are shipping without reputation/trust mechanisms
until a dedicated privacy-first design pass is completed and explicitly approved.

## Work Packages
### P5-PROTOCOL-1: Trust attestation TLV
- Goal: Attach signed quality claims to AgentInfo.
- Owned files: `bitchat/Models/AgentInfo.swift`,
  `bitchat/Protocols/Packets.swift`
- Interfaces:
  - `AgentAttestation { issuer, signature, claimsHash, expiresAt }`
  - AgentInfo v3 includes attestation blob (optional)
- Dependencies: P0-SPEC-1
- Done when: attestation can be encoded/decoded and ignored safely by v1.

### P5-STORE-1: Trust store + verification
- Goal: Verify attestation signatures and cache trust results.
- Owned files: `bitchat/Services/AgentTrustStore.swift` (new)
- Interfaces:
  - `verify(attestation) -> TrustScore`
  - `TrustScore` used by routing
- Dependencies: P5-PROTOCOL-1; soft: deferred payment reputation milestone (optional later input)
- Done when: routing can prefer trusted agents.

### P5-ROUTING-1: Trust-weighted selection
- Goal: Update selection to consider trust, quality, and reachability.
- Owned files: `bitchat/ViewModels/Extensions/ChatViewModel+AgentMeshRouting.swift` (new)
- Interfaces:
  - Score formula: `reachability > trust > quality > recency`
- Dependencies: P5-STORE-1; soft: deferred payment reputation milestone (optional later input)
- Done when: routing logs show trust-influenced decisions.
