# Phase 0 - Foundation and Test Harness

Goal: Stabilize specs, add test vectors, and set up feature flags so later
phases can land safely.

## Work Packages
### P0-SPEC-1: Agent Mesh constants + versioning
- Goal: Centralize protocol constants and a version byte for AgentInfo.
- Owned files: `bitchat/Protocols/AgentMeshConstants.swift` (new),
  `bitchat/Protocols/Packets.swift`
- Interfaces:
  - `enum AgentMeshConstants { static let agentInfoVersion: UInt8 = 1 ... }`
  - `enum AgentMeshTLV: UInt8 { case agentInfo = 0x05, ... }`
- Dependencies: none
- Done when: encode/decode functions use shared constants and version.

### P0-TEST-1: Packet encode/decode test vectors
- Goal: Ensure AgentInfo, AgentRequestPacket, AgentResponsePacket are stable.
- Owned files: `bitchatTests/AgentMeshPacketsTests.swift` (new)
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
