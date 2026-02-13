# Phase 0 - Foundation and Test Harness

Goal: Stabilize specs, add test vectors, and set up feature flags so later
phases can land safely.

Status: Complete
- Agent mesh constants and versioning centralized.
- Packet encode/decode tests added.
- Feature flags and logging hooks implemented.
- SwiftPM test entrypoint script added to avoid PATH/toolchain issues (`scripts/agent_mesh_test.sh`).

## Work Packages
### P0-SPEC-1: Agent Mesh constants + versioning
- Goal: Centralize protocol constants and a version byte for AgentInfo.
- Owned files: `bitchat/Protocols/AgentMeshConstants.swift` (new),
  `bitchat/Protocols/Packets.swift`
- Interfaces:
  - `enum AgentMeshConstants { static let agentInfoVersionV1: UInt8 = 0x01; static let agentInfoVersionV2: UInt8 = 0x02; static let agentInfoVersion = agentInfoVersionV2 ... }`
  - `enum AgentMeshTLV: UInt8 { case agentInfo = 0x05, ... }`
- Dependencies: none
- Done when: encode/decode functions use shared constants and version.

### P0-TEST-1: Packet encode/decode test vectors
- Goal: Ensure AgentInfo, AgentRequestPacket, AgentResponsePacket are stable.
- Owned files: `bitchatTests/Protocols/AgentMeshPacketsTests.swift`
- Interfaces: golden byte arrays for TLV payloads
- Dependencies: P0-SPEC-1
- Done when: tests pass for encode/decode and truncation behavior (255 byte cap).

### P0-FLAG-1: Feature flags and config schema
- Goal: Allow gated rollout per device.
- Owned files: `bitchat/Services/AgentMeshFeatureFlags.swift` (new),
  `bitchat/ViewModels/ChatViewModel.swift` (minimal hook only)
- Interfaces:
  - `struct AgentMeshFeatureFlags { var enableRuntime: Bool; ... }`
  - `UserDefaults` key namespace: `bitchat.agent.mesh.*`
- Dependencies: none
- Done when: runtime integration can be toggled without code changes.

### P0-OBS-1: Logging and debug hooks
- Goal: Consistent debug output for requests, responses, and routing.
- Owned files: `bitchat/Services/AgentMeshLogger.swift` (new)
- Interfaces: `AgentMeshLogger.log(_ event: AgentMeshEvent)`
- Dependencies: none
- Done when: request lifecycle logs appear with requestID and peerID.

### P0-SPEC-2: AgentInfo v2 + payment TLVs
- Goal: Extend protocol constants for payment terms and new payment packets.
- Owned files: `bitchat/Protocols/AgentMeshConstants.swift`,
  `bitchat/Protocols/Packets.swift`
- Interfaces:
  - `agentInfoVersion: UInt8 = 2`
  - TLVs for `paymentTerms` fields (rail, settlementMode, unit, pricePerRequest, acceptedMints, requestTTLSeconds)
  - Packet type constants for `AgentPaymentPayloadPacket`, `AgentPaymentReceiptPacket`,
    `MintProxyRequestPacket`, `MintProxyResponsePacket`
- Dependencies: P0-SPEC-1
- Done when: protocol constants cover payment terms and payment packets without breaking v1 decode.

### P0-TEST-2: Payment packet encode/decode vectors
- Goal: Add golden vectors for payment-related packets and AgentInfo v2.
- Owned files: `bitchatTests/Protocols/AgentMeshPacketsTests.swift`
- Interfaces:
  - AgentInfo v2 with `paymentTerms`
  - `AgentPaymentPayloadPacket`, `AgentPaymentReceiptPacket`
  - `MintProxyRequestPacket`, `MintProxyResponsePacket`
- Dependencies: P0-SPEC-2
- Done when: tests pass for all payment packets and v2 AgentInfo.

### P0-FLAG-2: Payments feature flag
- Goal: Gate payment UI and packet handling with a feature flag.
- Owned files: `bitchat/Services/AgentMeshFeatureFlags.swift`,
  `bitchat/ViewModels/ChatViewModel.swift`
- Interfaces:
  - `enablePayments: Bool`
  - `UserDefaults` key: `bitchat.agent.mesh.payments`
- Dependencies: P0-FLAG-1
- Done when: payment logic is disabled cleanly when the flag is off.
