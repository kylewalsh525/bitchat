# Beta Readiness Checklist (No Trust/Reputation)

This checklist is the minimum bar for shipping a TestFlight / limited beta for Agent Mesh + payments, without reputation/incentives.

## Builds
1. macOS app builds and runs from Xcode:
   - Scheme: `bitchat (macOS)`
   - Minimum macOS for beta: 14.5 (CashuDevKit artifacts)
2. iOS app builds and runs on a simulator/device:
   - Scheme: `bitchat (iOS)`

## First-Run Onboarding (Requester Path)
1. Fresh install launches onboarding automatically.
2. Nickname step:
   - Setting a nickname persists after app restart.
3. Permissions step:
   - Notifications request works (iOS).
   - Location enable works (optional).
4. Agents basics:
   - User understands `/agent …` and quote selection (tap or `/agentchoose`).
5. Wallet step is skippable:
   - Skipping still allows the app to be usable.
6. Finish step:
   - “Try an agent demo” pre-fills an `/agent` command in the composer.

## Settings Discoverability / IA
1. Gear icon is visible on the main screen header.
2. People/session list button in the header is reachable with VoiceOver and opens the sheet.
3. Settings contains:
   - Requester preferences
   - Wallet
   - Provider setup wizard
   - Panic wipe (visible, confirmed)
   - Support export
   - About
4. Navigation contract:
   - Root Settings owns dismissal (`Done`).
   - Destination pages use system back.
   - No destination traps the user (always `Back`/`Cancel`/`Done` path).
5. Performance:
   - Opening Settings and Wallet does not cause sustained UI freeze.
   - Console does not spam repeated `AttributeGraph cycle detected` during normal navigation.

## Wallet + Mint Allowlist (Fail-Closed)
1. Import token:
   - Pasting `cashuA` and `cashuB` tokens imports successfully.
   - Pasting prefixed token lines (`1: cashuB...`) imports successfully.
   - If token references an unknown mint, the user is prompted to approve it first.
2. Allowlist:
   - Approved mints list is editable (revoke works).
3. Balances:
   - Balance shows per mint + unit.
4. Export token:
   - Export works and “Copy/Share” works.
5. Payment safety:
   - Paying a request that references a non-allowlisted mint fails closed (UI offers “Approve mint”).
6. Live updates:
   - Wallet balances and reserved summaries update immediately while Wallet setup screen is open.
   - Burst wallet notifications do not visibly stutter the page (reloads are coalesced).

## X402 Rail (Optional, Online-Only)
1. Requester preferences:
   - User can enable/disable x402 and choose default rail (`cashu` or `x402`).
   - x402 disabled prevents x402-first routing preference.
   - x402 readiness panel updates live (`disabled`, `not configured`, `ready`) and deep-links to Wallet setup.
2. Guest wallet:
   - Wallet screen shows a guided x402 setup (no client-id field).
   - “Connect guest wallet” provisions/loads wallet address.
   - If the app build is missing `THIRDWEB_CLIENT_ID`, x402 shows as unavailable and connect is disabled.
   - Every thirdweb action shows explicit progress + success/failure status.
   - Wallet status panel updates in real-time (`readiness`, `wallet`, `linked`).
3. Provider wizard:
   - x402 rail fields (chain, token, pay-to, gateway URL) validate and persist.
4. Payment interstitial:
   - x402 prompts show gateway, chain, token, and pay-to context.
   - x402 prompt does not require Cashu mint allowlist approval.
5. Settlement:
   - provider finalizes x402 via `/x402/settle` and requester receives `finalized_online`.

## Provider Enablement Wizard (Optional)
1. Provider setup wizard is reachable from Settings.
2. Gateway mode:
   - “Test connection” and “Fetch catalog” work against `scripts/agent_gateway_proxy.py`.
   - Invalid gateway URL shows inline validation and blocks continue.
3. Payments:
   - Accepted mints are required when enabling payments.
   - `offline_accepted` defaults locking to `p2pk` (unsafe opt-out is explicit).
   - Notary policy controls are visible for offline mode.
4. Enabling:
   - Enabling provider mode broadcasts agent announce and peers can discover it.

## Paid Agent Flow (P2PK)
Run both cross-platform directions:

1. Provider macOS → Requester iOS:
   - Requester sends paid `/agent` request, sees “payment required” card.
   - Requester pays; provider accepts; requester resumes output after receipt.
2. Provider iOS → Requester macOS:
   - Same as above.

## Gateway Relock Fallback
1. Create a lock-required request (`requiresLocking = p2pk`).
2. Force direct requester→mint relock to fail (network block or unreachable).
3. Ensure a mesh peer can reach the mint via gateway path.
4. Retrying pay succeeds via gateway `relock`, then payload sends once.

## Support Bundle Export (Redacted)
1. Settings → Support → “Generate bundle” produces a file that can be shared.
2. Bundle contains:
   - app version/build, platform
   - feature flags
   - redacted agent config
   - wallet summary (no proofs)
   - payment store summary (no payloads/proofs)
   - recent agent/payment events (redacted)
3. Bundle does **not** contain:
   - `cashuA`/`cashuB` tokens
   - bearer proofs / secrets
   - lock private keys
   - gateway bearer token

## UX Polish Regression Checks
1. Quote card:
   - Shows `amount`, `mint`, and `expiry` without needing to scroll.
   - Shows settlement mode and locking mode labels.
2. Empty states:
   - `/agent` with no matching providers returns a helpful message.
   - Quote collection with no responses returns a clear retry prompt.
   - Wallet without imported funds shows a clear onboarding message.

## Panic Wipe
1. Settings → Panic wipe is present and requires confirmation.
2. After wiping:
   - chat history is cleared
   - wallet store is cleared (no proofs/reservations)
   - mint allowlist is cleared (no approved mints)
   - agent config + requester prefs reset (provider disabled)
   - agent sessions + memory stores are cleared
   - payment store + lock key bindings are cleared
   - app support caches/stores are cleared (`Application Support/bitchat/*` and media `Application Support/files/*`)
   - onboarding is shown again on next launch
