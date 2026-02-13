# Phase 6 - Sessions and Stateful Agents

Goal: Enable privacy-preserving multi-turn agent conversations with explicit session IDs and local memory tooling.

Status: Complete
- Session IDs round-trip in requests/responses and payment packets.
- Agent DM threads are keyed by ephemeral session IDs with per-session aliases.
- Local session store and `/agentsession` commands are implemented.
- Local memory store, memory UI, manual snippet attachment, and opt-in auto-recall are implemented.
- Session payment lifecycle state (`paid | accepted_offline | finalized | failed`) is stored and surfaced in session history UI.

## Milestone Status Snapshot
- `P6-EPHEM-1`: complete
- `P6-MEM-STORE-1`: complete
- `P6-MEM-UI-1`: complete
- `P6-MEM-RECALL-1`: complete
- `P6-UI-1`: complete
- `P6-MEM-WIPE-1`: complete
- `P6-MEM-1`: complete
- `P6-PROTOCOL-1`: complete
- `P6-PAY-1`: complete
- `P6-PAY-2`: complete
- `P6-STORE-1`: complete
- `P6-CMD-1`: complete

## Work Packages
### P6-EPHEM-1: Agent DM ephemeral enforcement (Implemented)
- Goal: Force fresh session IDs for new agent DMs and avoid identity-linking handles.
- Owned files: `bitchat/ViewModels/Extensions/ChatViewModel+AgentSessions.swift`
- Interfaces:
  - new sessions always generate a new `sessionID`
  - per-session sender alias (`anon-...`) is generated and carried in requests

### P6-MEM-STORE-1: Local memory store (Implemented)
- Goal: Local-only memory with curated and daily Markdown layers.
- Owned files: `bitchat/Services/AgentMemoryStore.swift`
- Interfaces:
  - curated file: `MEMORY.md`
  - daily logs: `memory/YYYY-MM-DD.md`
  - APIs: `listEntries()`, `readEntry()`, `writeEntry()`, `appendDaily()`, `wipeAllMemory()`

### P6-MEM-UI-1 + P6-MEM-1: Memory UI and snippet attachment (Implemented)
- Goal: Let users edit memory and control what gets attached to requests.
- Owned files: `bitchat/Views/AgentSettingsView.swift`, `bitchat/ViewModels/Extensions/ChatViewModel+AgentMemory.swift`
- Interfaces:
  - list/select/edit memory entries in settings
  - attach/detach entry snippets for agent requests
  - quick daily note append and save controls

### P6-MEM-RECALL-1: Auto-recall (Implemented)
- Goal: Opt-in local recall for relevant snippets.
- Owned files: `bitchat/Services/AgentMemoryRecall.swift`, `bitchat/ViewModels/Extensions/ChatViewModel+AgentMemory.swift`, `bitchat/ViewModels/ChatViewModel.swift`, `bitchat/ViewModels/Extensions/ChatViewModel+AgentSessions.swift`
- Interfaces:
  - toggle: `autoMemoryRecall`
  - keyword-based local recall
  - memory context is injected into outgoing prompts (local-only preprocessing)

### P6-STORE-1 + P6-CMD-1 + P6-UI-1: Session persistence/navigation (Implemented)
- Goal: Session history control without sacrificing ephemeral transport.
- Owned files: `bitchat/Services/AgentSessionStore.swift`, `bitchat/ViewModels/Extensions/ChatViewModel+AgentSessions.swift`, `bitchat/Views/SidebarSessionsView.swift`, `bitchat/Services/CommandProcessor.swift`
- Interfaces:
  - persisted session history with TTL/size caps
  - `/agentsession list|resume|new|end`
  - sidebar session list with resume and wipe actions

### P6-PROTOCOL-1 + P6-PAY-1 + P6-PAY-2: Session/payment binding (Implemented)
- Goal: Bind payment lifecycle to sessions and present lifecycle status.
- Owned files: `bitchat/Protocols/Packets.swift`, `bitchat/ViewModels/Extensions/ChatViewModel+AgentMeshPayments.swift`, `bitchat/Services/AgentSessionStore.swift`, `bitchat/Views/SidebarSessionsView.swift`
- Interfaces:
  - payment packets carry `sessionID` when available
  - session payment state transitions persisted and rendered
  - states: `paid`, `accepted_offline`, `finalized`, `failed`

## Validation Coverage
- `bitchatTests/Services/AgentSessionStoreTests.swift`
- `bitchatTests/Services/AgentMemoryStoreTests.swift`
- `bitchatTests/Services/AgentMemoryRecallTests.swift`
- `bitchatTests/ChatViewModelPaymentsTests.swift` (session/payment integration paths)

## Done When
- Users can start/resume/end agent sessions via commands and sidebar.
- Users can manage local memory entries, attach snippets, and opt into auto recall.
- Outgoing prompts include local memory context only on device.
- Payment lifecycle state is visible in session history and persists across restarts.
