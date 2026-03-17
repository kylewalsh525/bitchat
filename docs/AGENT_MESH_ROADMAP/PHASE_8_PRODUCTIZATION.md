# Phase 8 - Product Readiness and Apple-Level UX

Goal: Ship the missing product layer so Agent Mesh can be tested with real users (TestFlight / limited beta) without adding trust/reputation/incentives.

Status: Complete

## Milestone Status Snapshot
Implemented:
 - Settings entrypoint + IA (gear -> Settings, Agent/Wallet/Support/Panic discoverable)
- Requester first-run onboarding (requester-default, wallet step skippable)
- Provider enablement wizard (guided, safe defaults)
- Wallet UI (import/export/balance/reserved) + mint allowlist consent (fail-closed)
- Live wallet state reflection across Cashu + x402 (notification-driven refresh while Wallet/prompt UI is open)
- Support bundle export (redacted)
- macOS CashuDevKit linking + real P2PK locking (no stub; Xcode builds)
- Panic wipe now clears agent/payment/wallet state (stores + keychain) and app support caches
- Accessibility/dynamic type polish pass across core screens (header controls, quote cards, onboarding actions).
- Settings IA cleanup: Settings is now the primary home; App Info deep-links to Settings instead of parallel setup sheets.
- Payment card copy pass: amount/mint/expiry are always visible; settlement/locking risks are sentence-case and explicit.
- Onboarding copy pacing: reduced jargon and added short callouts for model-hash and payment safety.
- Provider wizard validation: inline gateway URL validation plus clear connection/catalog status states.
- Empty-state consistency: no providers / no quotes yet / no wallet balance phrasing aligned for first-time users.
- Beta checklist maintained in `docs/BETA_CHECKLIST.md`.

## Panel UX Critique
Resolved in this phase:
- Header tap targets now use explicit button affordances with accessibility labels/hints.
- Settings discoverability and routing now avoid hidden-only entrypoints.
- Payment interstitial cards now include mint approval state, settlement mode, locking mode, and expiry context.
- Onboarding and provider setup reduce dense copy and expose clear next actions.

## Scope Principles (Locked)
- No reputation/trust scoring mechanisms.
- Keep the “terminal vibe” as a brand accent, but improve hierarchy and accessibility.
- Default onboarding path is requester-first; provider enablement is optional and guided.
- Wallet setup during onboarding is optional; can be completed later from Settings.

## Work Packages
### P8-IA-1: Settings and Navigation IA
- Goal: Make agent/payments configuration discoverable without hidden gestures.
- Owned files:
  - `bitchat/Views/ContentView.swift`
  - `bitchat/Views/Settings/SettingsRootView.swift` (new)
- Done when:
  - Settings entrypoint is visible (gear).
  - Settings includes links to Agent Preferences, Provider Setup, Wallet, Panic wipe, About.

### P8-ONBOARD-1: Requester First-Run Onboarding
- Goal: Apple-level first-run experience that teaches the minimum viable workflow.
- Owned files:
  - `bitchat/Services/OnboardingStateStore.swift` (new)
  - `bitchat/Views/Onboarding/OnboardingFlowView.swift` (new)
  - `bitchat/Views/ContentView.swift`
- Done when:
  - On first run, onboarding appears via full-screen cover.
  - User can set nickname and learn how to use `/agent`.
  - Wallet step is skippable but accessible later.

### P8-ONBOARD-2: Provider Enablement Wizard (Optional)
- Goal: Guided provider setup with safe defaults.
- Owned files:
  - `bitchat/Views/Onboarding/ProviderSetupWizardView.swift` (new)
- Done when:
  - A non-engineer can configure role/model/runtime/payments and start advertising.
  - Offline acceptance defaults to P2PK lock; unsafe opt-outs are clearly warned.

### P8-WALLET-1: Wallet UI (Import/Export/Balance)
- Goal: Remove reliance on slash commands for Cashu wallet operations.
- Owned files:
  - `bitchat/Views/Wallet/WalletView.swift` (new)
- Done when:
  - Users can import tokens, view balances, export tokens, and see reserved summaries.

### P8-WALLET-2: Live Wallet State Reflection (Event-Driven Updates)
- Goal: Keep Wallet and payment prompt UI state accurate while flows are active (no pull-only-on-appear refresh).
- Owned files:
  - `bitchat/Services/WalletNotifications.swift` (new)
  - `bitchat/Services/CashuWalletService.swift`
  - `bitchat/Services/ThirdwebGuestWalletBridge.swift`
  - `bitchat/ViewModels/Extensions/ChatViewModel+AgentMeshPayments.swift`
  - `bitchat/Views/Wallet/WalletView.swift`
  - `bitchat/Views/Components/TextMessageView.swift`
- Done when:
  - Cashu wallet mutation emits `cashuWalletDidUpdate` only on real state changes.
  - Thirdweb guest wallet mutation emits `thirdwebWalletDidUpdate` on successful state changes.
  - Wallet balances/reserved update while the Wallet screen is open.
  - Payment prompt cards enable/disable actions based on current rail readiness (mint allowlist / x402 bridge config).

### P8-MINT-1: Mint Allowlist + Consent UX (Requester-side)
- Goal: Fail closed for unknown mints; require explicit user consent.
- Owned files:
  - `bitchat/Services/CashuMintAllowlistStore.swift` (new)
  - `bitchat/Views/Wallet/MintAllowlistView.swift` (new)
  - `bitchat/Services/CashuWalletService.swift`
- Done when:
  - Importing from new mint prompts for approval.
  - Paying a request for a non-allowlisted mint fails closed with an “Approve mint” path.

### P8-MACOS-LOCK-1: macOS CashuDevKit Link + Real P2PK
- Goal: Real cryptographic P2PK locking on macOS; remove insecure stubs.
- Note: CashuDevKit artifacts currently require macOS 14.5+ for app builds.
- Owned files:
  - `localPackages/Arti/Package.swift`
  - `Package.swift`
  - `bitchat/Services/CashuP2PKService.swift`
- Done when:
  - macOS build links without duplicate Rust runtime symbol errors.
  - `CashuP2PKService` uses CashuDevKit on macOS and passes tests.

### P8-COPY-1: In-App Disclosures and Risk Copy
- Goal: Users understand payment guarantees and limitations without reading docs.
- Owned files:
  - `bitchat/Views/Onboarding/OnboardingFlowView.swift`
  - `bitchat/Views/Wallet/WalletView.swift`
  - `bitchat/Views/Components/TextMessageView.swift`
- Done when:
  - `modelHash` is clearly described as self-attested.
  - Offline acceptance risk is clearly disclosed; locking/notary/settlement mitigation is described concisely.

### P8-SUPPORT-1: Support Bundle Export (Redacted)
- Goal: Enable beta feedback debugging without leaking bearer proofs/tokens/keys.
- Owned files:
  - `bitchat/Services/SupportBundleExporter.swift` (new)
  - `bitchat/Views/Settings/SettingsRootView.swift`
- Done when:
  - Export contains no Cashu tokens/proofs and no private keys.
  - Export includes build info, feature flags, redacted agent config, payment store summary, and recent event logs.

### P8-A11Y-1: Accessibility and Dynamic Type Pass
- Goal: Avoid power-user-only UI.
- Owned files:
  - `bitchat/Views/ContentView.swift`
  - `bitchat/Views/Onboarding/OnboardingFlowView.swift`
  - `bitchat/Views/Wallet/WalletView.swift`
- Done when:
  - Icon-only buttons have VoiceOver labels.
  - Core flows remain usable at Accessibility Dynamic Type sizes.

### P8-QA-1: Beta Readiness Checklist
- Goal: Single checklist for internal and external beta testing.
- Owned files:
  - `docs/BETA_CHECKLIST.md` (new) OR `docs/AGENT_MESH_SETUP.md`
- Done when:
  - Checklist covers onboarding, provider wizard, wallet/allowlist, P2PK across iOS/macOS, gateway relock fallback, and support bundle redaction.
