# Phase 1 - Real Agent Runtime (Gateway or Local)

Goal: Replace EchoAgentRuntime with a real runtime and configuration surface.

Status: Complete
- Runtime selection and config surface implemented.
- Gateway client/runtime implemented.
- Runtime status exposed via /agentconfig and UI system messages.
- Dedicated agent setup UI and manual model discovery are implemented.
- Requester-side agent routing preferences (min quality + known-model/hash hints) are implemented.
- Optional richer capability taxonomy/presentation remains iterative.

## Work Packages
### P1-COMPAT-1: Payment gating before runtime invocation
- Goal: Ensure unpaid requests never reach the runtime execution path.
- Owned files: `bitchat/ViewModels/ChatViewModel.swift`
- Interfaces:
  - If `paymentRequired`, halt before runtime invocation and await receipt.
  - Runtime interfaces remain unchanged.
- Dependencies: none (wired when Phase 4A payment signals are enabled)
- Done when: payment gating intercepts requests without modifying runtime APIs.

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
  - `/agentstream <on|off>`
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

### P1-UI-2: Agent setup + model discovery UI
- Goal: Provide a dedicated UI to configure agent settings and discover available agent types/models.
- Owned files: `bitchat/Views/AgentSettingsView.swift` (new),
  `bitchat/ViewModels/ChatViewModel.swift` (config binding),
  `bitchat/Services/AgentCatalogService.swift` (new)
- Interfaces:
  - Agent settings panel (enable, role, model, quality, runtime mode, stream toggle)
  - Agent catalog list (local runtime + gateway-supported model list)
  - “Capabilities” view that lists available roles and models with quality hints
  - Manual-only gateway discovery (no background scans); user taps “Fetch Models”
  - Gateway presets for local Ollama / LM Studio (via local gateway)
- Dependencies: P1-RUNTIME-1, P1-GW-1
- Done when: users can configure agent without commands and browse available models/roles.

### P1-MODEL-1: Model quality/hash preferences (requester-side)
- Goal: Allow requesters to prefer known open-source models using `modelHash` mapping that works offline.
- Owned files: `bitchat/Services/AgentKnownModelCatalog.swift` (new),
  `bitchat/Services/AgentKnownModelUpdateService.swift` (new),
  `bitchat/Services/AgentRequesterPreferences.swift` (new),
  `bitchat/Views/AgentPreferencesView.swift` (new),
  `bitchat/ViewModels/Extensions/ChatViewModel+AgentRoutingPreferences.swift` (new),
  `bitchat/ViewModels/ChatViewModel.swift`,
  `bitchat/ViewModels/Extensions/ChatViewModel+AgentSessions.swift`
- Interfaces:
  - `AgentInfo.modelHash` is an artifact digest (`ollama:sha256:<hex>` or `sha256:<hex>`) and is treated as a self-attested claim.
  - Preferences: `minQualityScore`, `preferKnownModels`, `preferredKnownModelIDs`, `penalizeUnknownModels`
- Dependencies: none
- Done when: requesters can set preferences in UI, routing respects preferences, and known model hash mappings can be refreshed once and used offline.
