# Phase 1 - Real Agent Runtime (Gateway or Local)

Goal: Replace EchoAgentRuntime with a real runtime and configuration surface.

## Work Packages
### P1-RUNTIME-1: Runtime selection + base protocol
- Goal: Add a runtime selector without breaking EchoAgentRuntime.
- Owned files: `bitchat/Services/AgentRuntime.swift`
- Interfaces:
  - `enum AgentRuntimeMode { case echo, gateway }`
  - `struct AgentRuntimeConfig { mode, timeoutMs, ... }`
- Dependencies: P0-FLAG-1
- Done when: ChatViewModel selects runtime based on config.

### P1-GW-1: Gateway client and runtime
- Goal: Implement `GatewayAgentRuntime` using an HTTP JSON API.
- Owned files: `bitchat/Services/AgentGatewayClient.swift` (new),
  `bitchat/Services/GatewayAgentRuntime.swift` (new)
- Interfaces:
  - Request JSON: `{ requestID, role, prompt, modelId, timeoutMs }`
  - Response JSON: `{ requestID, content, isError }`
  - Transport: `POST /agent/run` (local gateway URL from config)
- Dependencies: P1-RUNTIME-1
- Done when: a local gateway can return content into AgentResponsePacket.

### P1-CMD-1: Runtime config commands
- Goal: Allow users to configure runtime mode + gateway endpoint.
- Owned files: `bitchat/Services/CommandProcessor.swift`,
  `bitchat/Models/AgentInfo.swift` (config struct only)
- Interfaces (new commands):
  - `/agentruntime <echo|gateway>`
  - `/agentgateway <url>`
  - `/agenttoken <token>`
  - `/agenttimeout <seconds>`
- Dependencies: P1-RUNTIME-1
- Done when: `/agentconfig` prints runtime mode + endpoint status.

### P1-UI-1: Runtime status in UI
- Goal: Expose runtime mode and failures to the user.
- Owned files: `bitchat/ViewModels/Extensions/ChatViewModel+AgentMeshUI.swift` (new)
- Interfaces:
  - System message on runtime errors (gateway unreachable, timeout)
  - `/agentconfig` output includes runtime + endpoint health
- Dependencies: P1-GW-1, P1-CMD-1
- Done when: users can see runtime status without debugging.
