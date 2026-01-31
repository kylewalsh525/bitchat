# Phase 6 - Sessions and Stateful Agents

Goal: Enable multi-turn conversations with explicit session IDs.

Status: Partial
- Session IDs are carried in requests/responses.
- Agent DM threads are keyed by session ID with per-session aliases.
- No session store or /agentsession commands yet.

## Work Packages
### P6-EPHEM-1: Agent DM ephemeral enforcement
- Goal: Force new session IDs for all agent DMs and prevent identity linking.
- Owned files: `bitchat/ViewModels/Extensions/ChatViewModel+AgentSessions.swift`,
  `bitchat/Services/AgentSessionKey.swift` (new)
- Interfaces:
  - Always generate fresh sessionID for agent DMs.
  - Disable identity linking for any agent DM.
- Dependencies: P6-PROTOCOL-1
- Done when: no agent DM reuses session IDs.

### P6-MEM-1: Memory snippet export (local-only)
- Goal: Allow user-selected memory snippets to be attached to agent calls.
- Owned files: `bitchat/Services/AgentMemoryStore.swift` (new),
  `bitchat/ViewModels/Extensions/ChatViewModel+AgentMeshMemory.swift` (new)
- Interfaces:
  - `attachMemorySnippet(id)` only affects local request payload.
- Dependencies: P6-EPHEM-1
- Done when: memory snippets are user-selected and sent per request.

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
