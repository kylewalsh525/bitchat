# Agent Mesh Roadmap

This document captures forward-looking additions based on current design
intent. None of the items below are implemented yet.

## 1) Real LLM Runtime
### Goals
- Replace EchoAgentRuntime with real inference.
- Support local on-device models and remote gateways.

### Suggested Steps
- Implement a new AgentRuntime that calls a local gateway (e.g., Moltbot).
- Add retry/timeout handling (request expiration, user feedback).
- Support streaming by adding agentResponseChunk payload or chunk TLV.

## 2) Payments (Stablecoin)
### Goals
- Add micropayments per request or per token.
- Keep the mesh protocol compact and privacy-preserving.

### Protocol Options
Option A: extend AgentInfo
- paymentMethod, paymentAddress, pricePerRequest

Option B: extend AgentResponsePacket
- paymentRequest (invoice/address + amount)
- paymentMemo

### Flow Sketch
1) Caller sends /agent request.
2) Agent returns payment request metadata.
3) Caller pays via wallet.
4) Caller submits proof (preimage/tx) or auto-verify.
5) Agent returns final content or unlocks encrypted content.

## 3) Quality and Trust
### Goals
- Make agent quality more reliable than self-declared score.

### Ideas
- Signed quality attestations from trusted issuers.
- Proof-of-model hashes tied to attested benchmarks.
- Reputation based on local history.

## 4) Sessions and Stateful Agents
- Support multi-turn sessions with explicit session IDs.
- Store limited context with privacy rules.

## 5) Transport and Routing
- Add request fanout or bid/quote flow.
- Introduce TTL and idempotency for agent requests.
- Add a retry queue for agents that reconnect later.
