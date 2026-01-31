# Phase 6 - Sessions and Stateful Agents

Goal: Enable multi-turn conversations with explicit session IDs.

Status: Partial
- Session IDs are carried in requests/responses.
- Agent DM threads are keyed by session ID with per-session aliases.
- No session store or /agentsession commands yet.
- Memory UI, auto-recall, and wipe controls not yet implemented.

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

### P6-MEM-STORE-1: Local memory store (two-layer Markdown)
- Goal: Local-only memory with daily logs + curated long-term file.
- Owned files: `bitchat/Services/AgentMemoryStore.swift` (new)
- Interfaces:
  - `MEMORY.md` (curated) + `memory/YYYY-MM-DD.md` (daily append)
  - `listEntries()`, `readEntry()`, `writeEntry()`, `appendDaily()`
- Dependencies: P6-EPHEM-1
- Done when: memory files are editable and readable locally.

### P6-MEM-UI-1: Memory UI + attach to agent
- Goal: Provide a privacy-first memory viewer/editor and attach controls.
- Owned files: `bitchat/Views/AgentSettingsView.swift` (new),
  `bitchat/Views/Memory/*` (new)
- Interfaces:
  - List/edit MEMORY.md and daily logs
  - Attach selected snippets to agent DM requests
  - Clear memory button (one-tap)
- Dependencies: P6-MEM-STORE-1
- Done when: user can view/edit/attach memory without commands.

### P6-MEM-RECALL-1: Auto-recall (opt-in)
- Goal: Seamless context injection using local recall.
- Owned files: `bitchat/Services/AgentMemoryRecall.swift` (new),
  `bitchat/ViewModels/Extensions/ChatViewModel+AgentMeshMemory.swift` (new)
- Interfaces:
  - Toggle in Agent Settings: `autoMemoryRecall = on|off`
  - Recall strategy: keyword first, vector if available (local only)
- Dependencies: P6-MEM-UI-1
- Done when: relevant memory is auto-attached to agent prompts if enabled.

### P6-UI-1: Session history navigator
- Goal: Allow users to browse prior agent sessions and start a new session from a selected history.
- Owned files: `bitchat/Views/SidebarSessionsView.swift` (new),
  `bitchat/ViewModels/ChatViewModel.swift`
- Interfaces:
  - Sidebar tab: “Sessions”
  - List shows role, lastUsedAt, and a short title
  - Selecting a session or tapping “Resume” auto-starts a new ephemeral session using last N turns raw
- Dependencies: P6-STORE-1, P6-CMD-1
- Done when: users can start a new session from history without commands.

### P6-MEM-WIPE-1: One-tap wipe
- Goal: Allow instant deletion of all local memory and session state.
- Owned files: `bitchat/Services/AgentMemoryStore.swift`,
  `bitchat/Services/AgentSessionStore.swift`,
  `bitchat/Views/AgentSettingsView.swift`
- Interfaces:
  - `wipeAllMemory()`, `wipeAllSessions()`
- Dependencies: P6-MEM-UI-1
- Done when: user can wipe all memory and sessions immediately.

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
