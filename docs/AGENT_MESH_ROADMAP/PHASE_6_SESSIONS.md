# Phase 6 - Sessions and Stateful Agents

Goal: Enable multi-turn conversations with explicit session IDs.

## Work Packages
### P6-PROTOCOL-1: Session TLVs
- Goal: Carry session IDs in requests and responses.
- Owned files: `bitchat/Protocols/Packets.swift`
- Interfaces:
  - `AgentRequestPacket` adds `sessionID` (type 0x05)
  - `AgentResponsePacket` echoes `sessionID` (type 0x03)
- Dependencies: P0-SPEC-1
- Done when: session IDs round-trip across mesh.

### P6-STORE-1: Local session store
- Goal: Track sessions per peer/role with privacy controls.
- Owned files: `bitchat/Services/AgentSessionStore.swift` (new)
- Interfaces:
  - `startSession(role, peerID) -> sessionID`
  - `resumeSession(sessionID)`
  - TTL and max history controls
- Dependencies: P6-PROTOCOL-1
- Done when: `/agent` can reuse a prior session.

### P6-CMD-1: Session commands
- Goal: User control over sessions.
- Owned files: `bitchat/Services/CommandProcessor.swift`
- Interfaces:
  - `/agentsession new|resume|end [id]`
- Dependencies: P6-STORE-1
- Done when: session actions are reflected in `/agentconfig`.
