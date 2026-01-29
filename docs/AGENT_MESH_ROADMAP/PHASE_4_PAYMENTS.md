# Phase 4 - Payments (Micropayments)

Goal: Enable paid requests with optional invoices.

## Work Packages
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
