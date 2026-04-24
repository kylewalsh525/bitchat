//
// CommandProcessor.swift
// bitchat
//
// Handles command parsing and execution for BitChat
// This is free and unencumbered software released into the public domain.
//

import Foundation
import BitFoundation

/// Result of command processing
enum CommandResult {
    case success(message: String?)
    case error(message: String)
    case handled  // Command handled, no message needed
}

/// Simple struct for geo participant info used by CommandProcessor
struct CommandGeoParticipant {
    let id: String        // pubkey hex (lowercased)
    let displayName: String
}

/// Protocol defining what CommandProcessor needs from its context.
/// This breaks the circular dependency between CommandProcessor and ChatViewModel.
@MainActor
protocol CommandContextProvider: AnyObject {
    // MARK: - State Properties
    var nickname: String { get }
    var selectedPrivateChatPeer: PeerID? { get }
    var blockedUsers: Set<String> { get }
    var privateChats: [PeerID: [BitchatMessage]] { get set }
    var idBridge: NostrIdentityBridge { get }
    var agentConfig: AgentConfig { get }
    var agentRuntimeStatus: AgentRuntimeStatus { get }

    // MARK: - Peer Lookup
    func getPeerIDForNickname(_ nickname: String) -> PeerID?
    func getVisibleGeoParticipants() -> [CommandGeoParticipant]
    func nostrPubkeyForDisplayName(_ displayName: String) -> String?

    // MARK: - Chat Actions
    func startPrivateChat(with peerID: PeerID)
    func sendPrivateMessage(_ content: String, to peerID: PeerID)
    func clearCurrentPublicTimeline()
    func sendPublicRaw(_ content: String)
    func dispatchAgentRequest(role: String, prompt: String) -> CommandResult
    func handleAgentSessionCommand(_ args: String) -> CommandResult
    func updateAgentConfig(_ config: AgentConfig)

    // MARK: - System Messages
    func addLocalPrivateSystemMessage(_ content: String, to peerID: PeerID)
    func addPublicSystemMessage(_ content: String)

    // MARK: - Favorites
    func toggleFavorite(peerID: PeerID)
    func sendFavoriteNotification(to peerID: PeerID, isFavorite: Bool)
}

/// Processes chat commands in a focused, efficient way
@MainActor
final class CommandProcessor {
    weak var contextProvider: CommandContextProvider?
    weak var meshService: Transport?
    private let identityManager: SecureIdentityStateManagerProtocol

    init(contextProvider: CommandContextProvider? = nil, meshService: Transport? = nil, identityManager: SecureIdentityStateManagerProtocol) {
        self.contextProvider = contextProvider
        self.meshService = meshService
        self.identityManager = identityManager
    }
    
    /// Process a command string
    @MainActor
    func process(_ command: String) -> CommandResult {
        let parts = command.split(separator: " ", maxSplits: 1, omittingEmptySubsequences: false)
        guard let cmd = parts.first else { return .error(message: "Invalid command") }
        let args = parts.count > 1 ? String(parts[1]) : ""
        
        // Geohash context: disable favoriting in public geohash or GeoDM
        let inGeoPublic: Bool = {
            switch LocationChannelManager.shared.selectedChannel {
            case .mesh: return false
            case .location: return true
            }
        }()
        let inGeoDM = contextProvider?.selectedPrivateChatPeer?.isGeoDM == true

        switch cmd {
        case "/m", "/msg":
            return handleMessage(args)
        case "/w", "/who":
            return handleWho()
        case "/clear":
            return handleClear()
        case "/agent":
            return handleAgent(args)
        case "/agentconfig":
            return handleAgentConfig(args)
        case "/agentset":
            return handleAgentSet(args)
        case "/agenton":
            return handleAgentToggle(enabled: true)
        case "/agentoff":
            return handleAgentToggle(enabled: false)
        case "/agentquality":
            return handleAgentQuality(args)
        case "/agentruntime":
            return handleAgentRuntime(args)
        case "/agentgateway":
            return handleAgentGateway(args)
        case "/agenttoken":
            return handleAgentToken(args)
        case "/agenttimeout":
            return handleAgentTimeout(args)
        case "/agentstream":
            return handleAgentStream(args)
        case "/agentsession":
            return handleAgentSession(args)
        case "/hug":
            return handleEmote(args, command: "hug", action: "hugs", emoji: "🫂")
        case "/slap":
            return handleEmote(args, command: "slap", action: "slaps", emoji: "🐟", suffix: " around a bit with a large trout")
        case "/block":
            return handleBlock(args)
        case "/unblock":
            return handleUnblock(args)
        case "/fav":
            if inGeoPublic || inGeoDM { return .error(message: "favorites are only for mesh peers in #mesh") }
            return handleFavorite(args, add: true)
        case "/unfav":
            if inGeoPublic || inGeoDM { return .error(message: "favorites are only for mesh peers in #mesh") }
            return handleFavorite(args, add: false)
        default:
            return .error(message: "unknown command: \(cmd)")
        }
    }

    // MARK: - Command Handlers
    
    private func handleMessage(_ args: String) -> CommandResult {
        let parts = args.split(separator: " ", maxSplits: 1, omittingEmptySubsequences: false)
        guard !parts.isEmpty else {
            return .error(message: "usage: /msg @nickname [message]")
        }
        
        let targetName = String(parts[0])
        let nickname = targetName.hasPrefix("@") ? String(targetName.dropFirst()) : targetName
        
        guard let peerID = contextProvider?.getPeerIDForNickname(nickname) else {
            return .error(message: "'\(nickname)' not found")
        }

        contextProvider?.startPrivateChat(with: peerID)

        if parts.count > 1 {
            let message = String(parts[1])
            contextProvider?.sendPrivateMessage(message, to: peerID)
        }
        
        return .success(message: "started private chat with \(nickname)")
    }
    
    private func handleWho() -> CommandResult {
        // Show geohash participants when in a geohash channel; otherwise mesh peers
        switch LocationChannelManager.shared.selectedChannel {
        case .location(let ch):
            // Geohash context: show visible geohash participants (exclude self)
            guard let vm = contextProvider else { return .success(message: "nobody around") }
            let myHex = (try? vm.idBridge.deriveIdentity(forGeohash: ch.geohash))?.publicKeyHex.lowercased()
            let people = vm.getVisibleGeoParticipants().filter { person in
                if let me = myHex { return person.id.lowercased() != me }
                return true
            }
            let names = people.map { $0.displayName }
            if names.isEmpty { return .success(message: "no one else is online right now") }
            return .success(message: "online: " + names.sorted().joined(separator: ", "))
        case .mesh:
            // Mesh context: show connected peer nicknames
            guard let peers = meshService?.getPeerNicknames(), !peers.isEmpty else {
                return .success(message: "no one else is online right now")
            }
            let onlineList = peers.values.sorted().joined(separator: ", ")
            return .success(message: "online: \(onlineList)")
        }
    }
    
    private func handleClear() -> CommandResult {
        if let peerID = contextProvider?.selectedPrivateChatPeer {
            contextProvider?.privateChats[peerID]?.removeAll()
        } else {
            contextProvider?.clearCurrentPublicTimeline()
        }
        return .handled
    }

    private func handleAgent(_ args: String) -> CommandResult {
        let parts = args.split(separator: " ", maxSplits: 1, omittingEmptySubsequences: true)
        guard parts.count >= 2 else {
            return .error(message: "usage: /agent <role> <prompt>")
        }
        let role = String(parts[0])
        let prompt = String(parts[1])
        return contextProvider?.dispatchAgentRequest(role: role, prompt: prompt) ?? .error(message: "agent dispatch unavailable")
    }

    private func handleAgentConfig(_ args: String) -> CommandResult {
        let trimmed = args.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.isEmpty || trimmed == "show" else {
            return .error(message: "usage: /agentconfig")
        }
        guard let ctx = contextProvider else { return .error(message: "agent config unavailable") }
        let config = ctx.agentConfig
        let status = config.enabled ? "on" : "off"
        let hash = config.modelHash?.isEmpty == false ? " hash=\(config.modelHash!)" : ""
        let streamStatus = config.runtime.streamResponses ? "on" : "off"
        var runtime = "runtime=\(config.runtime.mode.rawValue) timeout=\(config.runtime.timeoutSeconds)s stream=\(streamStatus)"
        if config.runtime.mode == .gateway {
            let tokenStatus = (config.runtime.gatewayToken?.isEmpty == false) ? "token=set" : "token=unset"
            runtime += " url=\(config.runtime.gatewayURL) \(tokenStatus)"
            let health = ctx.agentRuntimeStatus
            if let err = health.lastGatewayError {
                runtime += " gateway=error(\(err))"
            } else if health.lastGatewaySuccessAt != nil {
                runtime += " gateway=ok"
            } else {
                runtime += " gateway=unknown"
            }
        }
        let paymentSummary: String = {
            guard let terms = config.paymentTerms?.sanitized() else { return "payments=off" }
            if terms.paymentRail == .x402 {
                let chain = terms.x402ChainID.map { "eip155:\($0)" } ?? "unknown"
                let token = terms.x402TokenAddress ?? "unknown"
                return "payments=x402 per_request=\(terms.pricePerRequest) \(terms.unit) chain=\(chain) token=\(token) mode=\(terms.settlementMode.rawValue)"
            }
            if terms.usesPerTokenPricing {
                let input = terms.pricePerInputToken ?? 0
                let output = terms.pricePerOutputToken ?? 0
                return "payments=\(terms.paymentRail.rawValue) per_token in=\(input) out=\(output) gran=\(terms.effectiveGranularityTokens) \(terms.unit) mode=\(terms.settlementMode.rawValue)"
            }
            return "payments=\(terms.paymentRail.rawValue) per_request=\(terms.pricePerRequest) \(terms.unit) mode=\(terms.settlementMode.rawValue)"
        }()
        let notary = config.notaryPolicy
        let notarySummary = "notary=node:\(notary.isNotaryCapable ? "on" : "off") k=\(notary.effectiveRequiredOfflineSignatures) timeout=\(notary.effectiveCollectTimeoutMs)ms"
        let message = "agent \(status): role=\(config.role) model=\(config.modelId) quality=\(config.qualityScore)\(hash) \(runtime) \(paymentSummary) \(notarySummary)"
        return .success(message: message)
    }

    private func handleAgentSet(_ args: String) -> CommandResult {
        let parts = args.split(separator: " ", omittingEmptySubsequences: true)
        guard parts.count >= 2 else {
            return .error(message: "usage: /agentset <role> <model> [quality] [hash]")
        }
        guard let ctx = contextProvider else { return .error(message: "agent config unavailable") }
        var next = ctx.agentConfig
        next.role = String(parts[0])
        next.modelId = String(parts[1])
        if parts.count >= 3, let q = UInt8(parts[2]), q <= 100 {
            next.qualityScore = q
        } else if parts.count >= 3 {
            return .error(message: "quality must be 0-100")
        }
        if parts.count >= 4 {
            next.modelHash = String(parts[3])
        }
        ctx.updateAgentConfig(next)
        return .success(message: "agent config updated")
    }

    private func handleAgentToggle(enabled: Bool) -> CommandResult {
        guard let ctx = contextProvider else { return .error(message: "agent config unavailable") }
        var next = ctx.agentConfig
        next.enabled = enabled
        ctx.updateAgentConfig(next)
        return .success(message: enabled ? "agent enabled" : "agent disabled")
    }

    private func handleAgentQuality(_ args: String) -> CommandResult {
        let trimmed = args.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let q = UInt8(trimmed), q <= 100 else {
            return .error(message: "usage: /agentquality <0-100>")
        }
        guard let ctx = contextProvider else { return .error(message: "agent config unavailable") }
        var next = ctx.agentConfig
        next.qualityScore = q
        ctx.updateAgentConfig(next)
        return .success(message: "agent quality set to \(q)")
    }

    private func handleAgentRuntime(_ args: String) -> CommandResult {
        let trimmed = args.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard trimmed == "echo" || trimmed == "gateway" else {
            return .error(message: "usage: /agentruntime <echo|gateway>")
        }
        guard let ctx = contextProvider else { return .error(message: "agent config unavailable") }
        var next = ctx.agentConfig
        next.runtime.mode = trimmed == "gateway" ? .gateway : .echo
        ctx.updateAgentConfig(next)
        return .success(message: "agent runtime set to \(next.runtime.mode.rawValue)")
    }

    private func handleAgentGateway(_ args: String) -> CommandResult {
        let trimmed = args.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            return .error(message: "usage: /agentgateway <url>")
        }
        guard let url = URL(string: trimmed), url.scheme?.hasPrefix("http") == true else {
            return .error(message: "invalid gateway url")
        }
        guard let ctx = contextProvider else { return .error(message: "agent config unavailable") }
        var next = ctx.agentConfig
        next.runtime.gatewayURL = trimmed
        ctx.updateAgentConfig(next)
        return .success(message: "agent gateway set")
    }

    private func handleAgentToken(_ args: String) -> CommandResult {
        let trimmed = args.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let ctx = contextProvider else { return .error(message: "agent config unavailable") }
        var next = ctx.agentConfig
        if trimmed.isEmpty {
            next.runtime.gatewayToken = nil
            ctx.updateAgentConfig(next)
            return .success(message: "agent token cleared")
        }
        next.runtime.gatewayToken = trimmed
        ctx.updateAgentConfig(next)
        return .success(message: "agent token set")
    }

    private func handleAgentTimeout(_ args: String) -> CommandResult {
        let trimmed = args.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let seconds = UInt32(trimmed), seconds > 0, seconds <= 300 else {
            return .error(message: "usage: /agenttimeout <seconds 1-300>")
        }
        guard let ctx = contextProvider else { return .error(message: "agent config unavailable") }
        var next = ctx.agentConfig
        next.runtime.timeoutSeconds = seconds
        ctx.updateAgentConfig(next)
        return .success(message: "agent timeout set to \(seconds)s")
    }

    private func handleAgentStream(_ args: String) -> CommandResult {
        let trimmed = args.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard trimmed == "on" || trimmed == "off" else {
            return .error(message: "usage: /agentstream <on|off>")
        }
        guard let ctx = contextProvider else { return .error(message: "agent config unavailable") }
        var next = ctx.agentConfig
        next.runtime.streamResponses = trimmed == "on"
        ctx.updateAgentConfig(next)
        return .success(message: "agent streaming set to \(trimmed)")
    }

    private func handleAgentSession(_ args: String) -> CommandResult {
        guard let ctx = contextProvider else { return .error(message: "agent sessions unavailable") }
        return ctx.handleAgentSessionCommand(args)
    }
    
    private func handleEmote(_ args: String, command: String, action: String, emoji: String, suffix: String = "") -> CommandResult {
        let targetName = args.trimmed
        guard !targetName.isEmpty else {
            return .error(message: "usage: /\(command) <nickname>")
        }
        
        let nickname = targetName.hasPrefix("@") ? String(targetName.dropFirst()) : targetName
        
        guard let targetPeerID = contextProvider?.getPeerIDForNickname(nickname),
              let myNickname = contextProvider?.nickname else {
            return .error(message: "cannot \(command) \(nickname): not found")
        }
        
        let emoteContent = "* \(emoji) \(myNickname) \(action) \(nickname)\(suffix) *"
        
        if contextProvider?.selectedPrivateChatPeer != nil {
            // In private chat
            if let peerNickname = meshService?.peerNickname(peerID: targetPeerID) {
                let personalMessage = "* \(emoji) \(myNickname) \(action) you\(suffix) *"
                meshService?.sendPrivateMessage(personalMessage, to: targetPeerID,
                                               recipientNickname: peerNickname,
                                               messageID: UUID().uuidString)
                // Also add a local system message so the sender sees a natural-language confirmation
                let pastAction: String = {
                    switch action {
                    case "hugs": return "hugged"
                    case "slaps": return "slapped"
                    default: return action.hasSuffix("e") ? action + "d" : action + "ed"
                    }
                }()
                let localText = "\(emoji) you \(pastAction) \(nickname)\(suffix)"
                contextProvider?.addLocalPrivateSystemMessage(localText, to: targetPeerID)
            }
        } else {
            // In public chat: send to active public channel (mesh or geohash)
            contextProvider?.sendPublicRaw(emoteContent)
            let publicEcho = "\(emoji) \(myNickname) \(action) \(nickname)\(suffix)"
            contextProvider?.addPublicSystemMessage(publicEcho)
        }
        
        return .handled
    }
    
    private func handleBlock(_ args: String) -> CommandResult {
        let targetName = args.trimmed
        
        if targetName.isEmpty {
            // List blocked users (mesh) and geohash (Nostr) blocks
            let meshBlocked = contextProvider?.blockedUsers ?? []
            var blockedNicknames: [String] = []
            if let peers = meshService?.getPeerNicknames() {
                for (peerID, nickname) in peers {
                    if let fingerprint = meshService?.getFingerprint(for: peerID),
                       meshBlocked.contains(fingerprint) {
                        blockedNicknames.append(nickname)
                    }
                }
            }

            // Geohash blocked names (prefer visible display names; fallback to #suffix)
            let geoBlocked = Array(identityManager.getBlockedNostrPubkeys())
            var geoNames: [String] = []
            if let vm = contextProvider {
                let visible = vm.getVisibleGeoParticipants()
                let visibleIndex = Dictionary(uniqueKeysWithValues: visible.map { ($0.id.lowercased(), $0.displayName) })
                for pk in geoBlocked {
                    if let name = visibleIndex[pk.lowercased()] {
                        geoNames.append(name)
                    } else {
                        let suffix = String(pk.suffix(4))
                        geoNames.append("anon#\(suffix)")
                    }
                }
            }

            let meshList = blockedNicknames.isEmpty ? "none" : blockedNicknames.sorted().joined(separator: ", ")
            let geoList = geoNames.isEmpty ? "none" : geoNames.sorted().joined(separator: ", ")
            return .success(message: "blocked peers: \(meshList) | geohash blocks: \(geoList)")
        }
        
        let nickname = targetName.hasPrefix("@") ? String(targetName.dropFirst()) : targetName
        
        if let peerID = contextProvider?.getPeerIDForNickname(nickname),
           let fingerprint = meshService?.getFingerprint(for: peerID) {
            if identityManager.isBlocked(fingerprint: fingerprint) {
                return .success(message: "\(nickname) is already blocked")
            }
            // Block the user (mesh/noise identity)
            if var identity = identityManager.getSocialIdentity(for: fingerprint) {
                identity.isBlocked = true
                identity.isFavorite = false
                identityManager.updateSocialIdentity(identity)
            } else {
                let blockedIdentity = SocialIdentity(
                    fingerprint: fingerprint,
                    localPetname: nil,
                    claimedNickname: nickname,
                    trustLevel: .unknown,
                    isFavorite: false,
                    isBlocked: true,
                    notes: nil
                )
                identityManager.updateSocialIdentity(blockedIdentity)
            }
            return .success(message: "blocked \(nickname). you will no longer receive messages from them")
        }
        // Mesh lookup failed; try geohash (Nostr) participant by display name
        if let pub = contextProvider?.nostrPubkeyForDisplayName(nickname) {
            if identityManager.isNostrBlocked(pubkeyHexLowercased: pub) {
                return .success(message: "\(nickname) is already blocked")
            }
            identityManager.setNostrBlocked(pub, isBlocked: true)
            return .success(message: "blocked \(nickname) in geohash chats")
        }
        
        return .error(message: "cannot block \(nickname): not found or unable to verify identity")
    }
    
    private func handleUnblock(_ args: String) -> CommandResult {
        let targetName = args.trimmed
        guard !targetName.isEmpty else {
            return .error(message: "usage: /unblock <nickname>")
        }
        
        let nickname = targetName.hasPrefix("@") ? String(targetName.dropFirst()) : targetName
        
        if let peerID = contextProvider?.getPeerIDForNickname(nickname),
           let fingerprint = meshService?.getFingerprint(for: peerID) {
            if !identityManager.isBlocked(fingerprint: fingerprint) {
                return .success(message: "\(nickname) is not blocked")
            }
            identityManager.setBlocked(fingerprint, isBlocked: false)
            return .success(message: "unblocked \(nickname)")
        }
        // Try geohash unblock
        if let pub = contextProvider?.nostrPubkeyForDisplayName(nickname) {
            if !identityManager.isNostrBlocked(pubkeyHexLowercased: pub) {
                return .success(message: "\(nickname) is not blocked")
            }
            identityManager.setNostrBlocked(pub, isBlocked: false)
            return .success(message: "unblocked \(nickname) in geohash chats")
        }
        return .error(message: "cannot unblock \(nickname): not found")
    }
    
    private func handleFavorite(_ args: String, add: Bool) -> CommandResult {
        let targetName = args.trimmed
        guard !targetName.isEmpty else {
            return .error(message: "usage: /\(add ? "fav" : "unfav") <nickname>")
        }
        
        let nickname = targetName.hasPrefix("@") ? String(targetName.dropFirst()) : targetName
        
        guard let peerID = contextProvider?.getPeerIDForNickname(nickname),
              let noisePublicKey = Data(hexString: peerID.id) else {
            return .error(message: "can't find peer: \(nickname)")
        }
        
        if add {
            let existingFavorite = FavoritesPersistenceService.shared.getFavoriteStatus(for: noisePublicKey)
            FavoritesPersistenceService.shared.addFavorite(
                peerNoisePublicKey: noisePublicKey,
                peerNostrPublicKey: existingFavorite?.peerNostrPublicKey,
                peerNickname: nickname
            )
            
            contextProvider?.toggleFavorite(peerID: peerID)
            contextProvider?.sendFavoriteNotification(to: peerID, isFavorite: true)
            
            return .success(message: "added \(nickname) to favorites")
        } else {
            FavoritesPersistenceService.shared.removeFavorite(peerNoisePublicKey: noisePublicKey)
            
            contextProvider?.toggleFavorite(peerID: peerID)
            contextProvider?.sendFavoriteNotification(to: peerID, isFavorite: false)
            
            return .success(message: "removed \(nickname) from favorites")
        }
    }
    
}
