# Phase 3 - Streaming Responses

Goal: Allow large responses to arrive as chunks.

Status: Complete
- Added streaming payload type + chunk packet.
- Added streaming runtime adapter (AsyncStream) with default fallback.
- Incremental UI rendering with timeout + retry support.
- Optional toggle via `/agentstream <on|off>`.
- Added deterministic unit tests for final-chunk cleanup and payment-gated streaming behavior.

## Work Packages
### P3-PROTOCOL-1: Response chunk payload
- Goal: Define a new Noise payload type for chunks.
- Owned files: `bitchat/Protocols/BitchatProtocol.swift`,
  `bitchat/Protocols/Packets.swift`
- Interfaces:
  - `NoisePayloadType.agentResponseChunk = 0x22`
  - `AgentResponseChunkPacket { requestID, index, isFinal, content, isError }`
- Dependencies: P0-SPEC-1
- Done when: encode/decode tests pass for chunk packets.

### P3-RUNTIME-1: Streaming runtime adapter
- Goal: Support streaming from a runtime (gateway or local).
- Owned files: `bitchat/Services/AgentRuntime.swift`,
  `bitchat/Services/GatewayAgentRuntime.swift`
- Interfaces:
  - `protocol StreamingAgentRuntime { func runStream(...) -> AsyncStream<AgentResponseChunkPacket> }`
  - Default adapter: if only `run` exists, emit one chunk.
- Dependencies: P3-PROTOCOL-1
- Done when: runtime can emit chunk streams without breaking echo mode.

### P3-RECEIVER-1: Chunk assembly + UI
- Goal: Render partial responses incrementally.
- Owned files: `bitchat/ViewModels/Extensions/ChatViewModel+AgentMeshStreaming.swift` (new),
  `bitchat/Views/` (new minimal UI helper if needed)
- Interfaces:
  - `AgentStreamingBuffer` per requestID with throttled UI updates
  - Final chunk closes the message and clears pending state
- Dependencies: P3-PROTOCOL-1
- Done when: users see streamed text progressively.

### P3-PAY-1: Streaming payment gating
- Goal: Pause output until a payment receipt is accepted.
- Owned files: `bitchat/ViewModels/Extensions/ChatViewModel+AgentMeshStreaming.swift`
- Interfaces:
  - If `paymentRequired`, suspend chunk rendering until receipt arrives.
  - Handle a `paymentRequired` interstitial without corrupting the stream buffer.
- Dependencies: P4-AUTH-1, P4-FLOW-1
- Delivery note: co-deliver with Phase 4A payment interstitial UX.
- Done when: streaming resumes cleanly after payment acceptance.
