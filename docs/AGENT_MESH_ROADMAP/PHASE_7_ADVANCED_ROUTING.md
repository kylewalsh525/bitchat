# Phase 7 - Advanced Routing (Fanout + Bids)

Goal: Allow multiple agents to compete or collaborate.

Status: Not started

## Work Packages
### P7-SELECT-1: Quality + price + model hash routing policy
- Goal: Select agents by quality threshold, allowed hashes, and price.
- Owned files: `bitchat/ViewModels/Extensions/ChatViewModel+AgentMeshRouting.swift` (new)
- Interfaces:
  - `minQuality`, `allowedModelHashes`, `maxPrice` local filters
- Dependencies: P4-MARKET-1
- Done when: selection honors local policy filters.

### P7-BID-1: Bid/quote before accept
- Goal: Allow agents to send quotes (price/ETA) before acceptance.
- Owned files: `bitchat/Protocols/BitchatProtocol.swift`,
  `bitchat/Protocols/Packets.swift`
- Interfaces:
  - `agentBid` payload type (0x23)
  - `AgentBidPacket { requestID, price, etaMs, modelHash }`
- Dependencies: P4-MARKET-1
- Done when: caller can select best bid and proceed to payment.

### P7-PROTOCOL-1: Bid/quote payloads
- Goal: Support bid/quote flows for fanout requests.
- Owned files: `bitchat/Protocols/BitchatProtocol.swift`,
  `bitchat/Protocols/Packets.swift`
- Interfaces:
  - `agentBid` payload type (0x23)
  - `AgentBidPacket { requestID, price, etaMs, modelId }`
- Dependencies: P4-PROTOCOL-1
- Done when: bid packets can be sent and decoded.

### P7-ROUTING-1: Fanout request mode
- Goal: Send a request to multiple agents and pick best bid.
- Owned files: `bitchat/ViewModels/Extensions/ChatViewModel+AgentMeshFanout.swift` (new)
- Interfaces:
  - `/agent --fanout <role> <prompt>`
  - Selection by bid price, trust, or quality
- Dependencies: P7-PROTOCOL-1
- Done when: fanout returns a single chosen response.
