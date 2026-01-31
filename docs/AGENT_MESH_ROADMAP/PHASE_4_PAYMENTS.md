# Phase 4 - Payments (Micropayments)

Goal: Enable paid requests with optional invoices.

Status: Not started

## Work Packages
### P4-MARKET-1: Price + payment terms in AgentInfo
- Goal: Advertise price, currency, and payment rail so callers can filter.
- Owned files: `bitchat/Models/AgentInfo.swift`,
  `bitchat/Protocols/Packets.swift`
- Interfaces:
  - AgentInfo adds: `pricePerRequest`, `currency`, `paymentRail`, `minQuality`
- Dependencies: P0-SPEC-1
- Done when: callers can filter agents by price/rail/quality locally.

### P4-AUTH-1: Payment required response flow
- Goal: Gate final responses behind payment proof.
- Owned files: `bitchat/ViewModels/Extensions/ChatViewModel+AgentMeshPayments.swift` (new),
  `bitchat/Protocols/Packets.swift`
- Interfaces:
  - AgentResponsePacket adds: `paymentRequired` (bool), `paymentRequest` (string)
- Dependencies: P4-MARKET-1
- Done when: unpaid requests respond with paymentRequired + paymentRequest.

### P4-LOCAL-1: Rail-agnostic payment bridge (stub)
- Goal: Allow multiple micropayment rails (Lightning, stablecoin) without lock-in.
- Owned files: `bitchat/Services/AgentPaymentBridge.swift` (new)
- Interfaces:
  - `protocol AgentPaymentBridge { pay(request) -> proof }`
  - Config selects `paymentRail` but remains open/agnostic.
- Dependencies: P4-AUTH-1
- Done when: local stub can return a payment proof for testing.

### P4-PROTOCOL-1: Payment metadata in AgentInfo + Response
- Goal: Advertise price and payment method.
- Owned files: `bitchat/Models/AgentInfo.swift`,
  `bitchat/Protocols/Packets.swift`
- Interfaces:
  - AgentInfo v2 adds: `paymentMethod`, `paymentAddress`, `pricePerRequest`
  - AgentResponsePacket adds: `paymentRequest` (string), `paymentRequired` (bool)
- Dependencies: P0-SPEC-1
- Done when: v1 clients ignore unknown fields safely.

### P4-FLOW-1: Payment request flow
- Goal: Require payment before sending final content.
- Owned files: `bitchat/ViewModels/Extensions/ChatViewModel+AgentMeshPayments.swift` (new)
- Interfaces:
  - If `paymentRequired`, show system message with `paymentRequest`
  - `/agentpay <requestID> <proof>` submits proof (stubbed)
- Dependencies: P4-PROTOCOL-1
- Done when: unpaid requests stop at payment request step.

### P4-STORE-1: Payment proofs store
- Goal: Cache proofs to avoid double payment prompts.
- Owned files: `bitchat/Services/AgentPaymentStore.swift` (new)
- Interfaces:
  - `recordProof(requestID, proof)`
  - `hasProof(requestID)`
- Dependencies: P4-FLOW-1
- Done when: paid requests complete without reprompt.
