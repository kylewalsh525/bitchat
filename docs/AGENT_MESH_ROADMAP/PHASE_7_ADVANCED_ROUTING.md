# Phase 7 - Advanced Routing (Tiered Quotes, No Order Book)

Goal: route `/agent` requests across multiple reachable providers using deterministic quality/model preferences plus simple quote tiers (`immediate`, `wait ~15s`, `wait ~60s`) instead of a bid/order-book market.

Status: Complete
Note: trust/reputation remains deferred; Phase 7 stays reputation-free.

## Scope Decision
- Replaced prior fanout+bids plan with a simpler quote-tier model.
- Requester asks a small candidate set for quotes, chooses one option, then sends a normal `AgentRequestPacket` bound to that quote.
- Payment request generation still happens only after the selected provider receives the chosen request.

## Work Packages
### P7-SELECT-1: Deterministic Candidate Shortlist
- Goal: Build a deterministic candidate list using role, reachability, quality floor, requester model preferences, and payment filter compatibility.
- Owned files: `bitchat/ViewModels/Extensions/ChatViewModel+AgentRoutingPreferences.swift`
- Interfaces:
  - Preferences: `minQualityScore`, `preferKnownModels`, `preferredKnownModelIDs`, `penalizeUnknownModels`
  - Payment compatibility filter: `unit`, `settlementMode`, `acceptedMints`, `requestTTLSeconds`
- Dependencies: P1-MODEL-1, P4-MARKET-1
- Done when: ordering is stable and deterministic.
- Status: complete

### P7-QUOTE-1: Quote Discovery Protocol
- Goal: Request per-provider tier options before dispatch.
- Owned files: `bitchat/Protocols/BitchatProtocol.swift`, `bitchat/Protocols/Packets.swift`, `bitchat/Protocols/AgentMeshConstants.swift`, `bitchat/Services/Transport.swift`, `bitchat/Services/BLE/BLEService.swift`
- Interfaces:
  - `agentBid` (`0x23`) is used as quote-request payload type (`AgentQuoteRequestPacket`)
  - `agentQuote` (`0x28`) is quote-response payload type (`AgentQuoteResponsePacket`)
  - Quote options carry `estimatedPrice`, `unit`, `settlementMode`, `acceptedMints`, `requestTTLSeconds`, `qualityScore`, `modelId`, `modelHash`, and `waitSeconds`
- Dependencies: P4-MARKET-1
- Done when: request/response quote packets encode/decode and transport end-to-end.
- Status: complete

### P7-QUOTE-2: Requester Selection + Dispatch
- Goal: Let requester choose one quoted tier and dispatch exactly one request.
- Owned files: `bitchat/ViewModels/Extensions/ChatViewModel+AgentMeshQuotes.swift`, `bitchat/ViewModels/ChatViewModel.swift`, `bitchat/Models/CommandInfo.swift`, `bitchat/Services/AutocompleteService.swift`
- Interfaces:
  - `/agent <role> <prompt>` triggers quote collection when eligible providers support per-request pricing
  - `/agentchoose <quoteID> <optionIndex>` selects an option and sends one request
  - tap-to-choose quote UI is available in composer quote cards
  - `AgentRequestPacket` carries `quoteID` + `quoteOptionID`
- Dependencies: P7-QUOTE-1
- Done when: quoted selection sends one request with quote binding fields.
- Status: complete

### P7-QUEUE-1: Wait-Tier Enforcement + Pricing Binding
- Goal: Enforce discounted wait tiers and bind quoted price to payment setup.
- Owned files: `bitchat/ViewModels/Extensions/ChatViewModel+AgentMeshQuotes.swift`, `bitchat/ViewModels/ChatViewModel.swift`, `bitchat/ViewModels/Extensions/ChatViewModel+AgentMeshPayments.swift`
- Interfaces:
  - Requester delays send for non-immediate tiers
  - Provider validates quote wait window before accepting quoted option
  - Quoted amount override is passed into per-request payment request generation
  - Retry path preserves `quoteID`/`quoteOptionID`
- Dependencies: P4-RELIABILITY-*, P4-PAYMENT-INTERSTITIAL
- Done when: discounted tiers enforce delay semantics and pricing remains stable through retries.
- Status: complete

### P7-NEXT-1: UX Follow-ons (Implemented)
- Goal: reduce command-driven friction after core quote routing is stable.
- Implemented:
  - tap-to-choose quote UI (in addition to `/agentchoose`)
  - optional auto-pick policy (`manual`, `cheapest`, `fastest`, `best-quality-under-budget`)
  - configurable per-provider quote tier table in Agent Settings (`immediate`, `standard`, `economy` wait/discount)
  - quote lifecycle cleanup with TTL expiry, pending-state pruning, and draft attachment restoration
