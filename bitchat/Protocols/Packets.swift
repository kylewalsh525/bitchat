import Foundation

// MARK: - Protocol TLV Packets

struct AnnouncementPacket {
    let nickname: String
    let noisePublicKey: Data            // Noise static public key (Curve25519.KeyAgreement)
    let signingPublicKey: Data          // Ed25519 public key for signing
    let directNeighbors: [Data]?        // 8-byte peer IDs
    let agentInfo: AgentInfo?           // Optional agent capability info

    init(
        nickname: String,
        noisePublicKey: Data,
        signingPublicKey: Data,
        directNeighbors: [Data]?,
        agentInfo: AgentInfo? = nil
    ) {
        self.nickname = nickname
        self.noisePublicKey = noisePublicKey
        self.signingPublicKey = signingPublicKey
        self.directNeighbors = directNeighbors
        self.agentInfo = agentInfo
    }

    private enum TLVType: UInt8 {
        case nickname = 0x01
        case noisePublicKey = 0x02
        case signingPublicKey = 0x03
        case directNeighbors = 0x04
    }

    func encode() -> Data? {
        var data = Data()
        // Reserve: TLVs for nickname (2 + n), noise key (2 + 32), signing key (2 + 32)
        data.reserveCapacity(2 + min(nickname.count, 255) + 2 + noisePublicKey.count + 2 + signingPublicKey.count)

        // TLV for nickname
        guard let nicknameData = nickname.data(using: .utf8), nicknameData.count <= 255 else { return nil }
        data.append(TLVType.nickname.rawValue)
        data.append(UInt8(nicknameData.count))
        data.append(nicknameData)

        // TLV for noise public key
        guard noisePublicKey.count <= 255 else { return nil }
        data.append(TLVType.noisePublicKey.rawValue)
        data.append(UInt8(noisePublicKey.count))
        data.append(noisePublicKey)

        // TLV for signing public key
        guard signingPublicKey.count <= 255 else { return nil }
        data.append(TLVType.signingPublicKey.rawValue)
        data.append(UInt8(signingPublicKey.count))
        data.append(signingPublicKey)
        
        // TLV for direct neighbors (optional)
        if let neighbors = directNeighbors, !neighbors.isEmpty {
            let neighborsData = neighbors.prefix(10).reduce(Data()) { $0 + $1 }
            if !neighborsData.isEmpty && neighborsData.count % 8 == 0 {
                data.append(TLVType.directNeighbors.rawValue)
                data.append(UInt8(neighborsData.count))
                data.append(neighborsData)
            }
        }

        // TLV for agent info (optional)
        if let agentInfo {
            let agentData = encodeAgentInfo(agentInfo)
            if agentData.count <= AgentMeshConstants.maxTLVStringBytes {
                data.append(AgentMeshTLV.agentInfo.rawValue)
                data.append(UInt8(agentData.count))
                data.append(agentData)
            }
        }

        return data
    }

    static func decode(from data: Data) -> AnnouncementPacket? {
        var offset = 0
        var nickname: String?
        var noisePublicKey: Data?
        var signingPublicKey: Data?
        var directNeighbors: [Data]?
        var agentInfo: AgentInfo?

        while offset + 2 <= data.count {
            let typeRaw = data[offset]
            offset += 1
            let length = Int(data[offset])
            offset += 1

            guard offset + length <= data.count else { return nil }
            let value = data[offset..<offset + length]
            offset += length

            if let type = TLVType(rawValue: typeRaw) {
                switch type {
                case .nickname:
                    nickname = String(data: value, encoding: .utf8)
                case .noisePublicKey:
                    noisePublicKey = Data(value)
                case .signingPublicKey:
                    signingPublicKey = Data(value)
                case .directNeighbors:
                    if length > 0 && length % 8 == 0 {
                        var neighbors = [Data]()
                        let count = length / 8
                        for i in 0..<count {
                            let start = value.startIndex + i * 8
                            let end = start + 8
                            neighbors.append(Data(value[start..<end]))
                        }
                        directNeighbors = neighbors
                    }
                }
            } else {
                if typeRaw == AgentMeshTLV.agentInfo.rawValue {
                    agentInfo = decodeAgentInfo(Data(value))
                }
                // Unknown TLV; skip (tolerant decoder for forward compatibility)
                continue
            }
        }

        guard let nickname = nickname, let noisePublicKey = noisePublicKey, let signingPublicKey = signingPublicKey else { return nil }
        return AnnouncementPacket(
            nickname: nickname,
            noisePublicKey: noisePublicKey,
            signingPublicKey: signingPublicKey,
            directNeighbors: directNeighbors,
            agentInfo: agentInfo
        )
    }
}

func encodeAgentInfo(_ info: AgentInfo) -> Data {
    let v1 = encodeAgentInfoV1(info)
    guard let paymentTerms = info.paymentTerms?.sanitized() else {
        return v1
    }

    var v2 = Data()
    v2.append(AgentMeshConstants.agentInfoVersionV2)
    v2.append(v1.dropFirst())

    var ext = Data()
    appendAgentInfoPaymentTLV(.paymentRail, string: paymentTerms.paymentRail.rawValue, into: &ext)
    appendAgentInfoPaymentTLV(.settlementMode, string: paymentTerms.settlementMode.rawValue, into: &ext)
    appendAgentInfoPaymentTLV(.requiresLocking, string: (paymentTerms.requiresLocking ?? .none).rawValue, into: &ext)
    appendAgentInfoPaymentTLV(.unit, string: paymentTerms.unit, into: &ext)
    appendAgentInfoPaymentTLV(.priceModel, string: paymentTerms.effectivePriceModel.rawValue, into: &ext)
    appendAgentInfoPaymentTLV(.pricePerRequest, uint64: paymentTerms.pricePerRequest, into: &ext)
    if let pricePerInputToken = paymentTerms.pricePerInputToken, pricePerInputToken > 0 {
        appendAgentInfoPaymentTLV(.pricePerInputToken, uint64: pricePerInputToken, into: &ext)
    }
    if let pricePerOutputToken = paymentTerms.pricePerOutputToken, pricePerOutputToken > 0 {
        appendAgentInfoPaymentTLV(.pricePerOutputToken, uint64: pricePerOutputToken, into: &ext)
    }
    if let minDeposit = paymentTerms.minDeposit, minDeposit > 0 {
        appendAgentInfoPaymentTLV(.minDeposit, uint64: minDeposit, into: &ext)
    }
    if paymentTerms.usesPerTokenPricing {
        appendAgentInfoPaymentTLV(.granularityTokens, uint32: paymentTerms.effectiveGranularityTokens, into: &ext)
    }
    if paymentTerms.paymentRail == .cashu {
        for mint in paymentTerms.acceptedMints {
            appendAgentInfoPaymentTLV(.acceptedMint, string: mint, into: &ext)
        }
    }
    if paymentTerms.paymentRail == .x402 {
        if let chainID = paymentTerms.x402ChainID, chainID > 0 {
            appendAgentInfoPaymentTLV(.x402ChainID, uint64: chainID, into: &ext)
        }
        if let token = paymentTerms.x402TokenAddress, !token.isEmpty {
            appendAgentInfoPaymentTLV(.x402TokenAddress, string: token, into: &ext)
        }
        if let payTo = paymentTerms.x402PayTo, !payTo.isEmpty {
            appendAgentInfoPaymentTLV(.x402PayTo, string: payTo, into: &ext)
        }
        if let gatewayURL = paymentTerms.x402GatewayURL, !gatewayURL.isEmpty {
            appendAgentInfoPaymentTLV(.x402GatewayURL, string: gatewayURL, into: &ext)
        }
        if let scheme = paymentTerms.x402Scheme?.rawValue, !scheme.isEmpty {
            appendAgentInfoPaymentTLV(.x402Scheme, string: scheme, into: &ext)
        }
        if let facilitator = paymentTerms.x402FacilitatorID, !facilitator.isEmpty {
            appendAgentInfoPaymentTLV(.x402FacilitatorID, string: facilitator, into: &ext)
        }
    }
    appendAgentInfoPaymentTLV(.requestTTLSeconds, uint32: paymentTerms.requestTTLSeconds, into: &ext)

    if v2.count + ext.count > AgentMeshConstants.maxTLVStringBytes {
        return v1
    }
    v2.append(ext)
    return v2
}

func decodeAgentInfo(_ data: Data) -> AgentInfo? {
    var offset = 0
    guard data.count >= 6 else { return nil }
    let version = data[offset]
    offset += 1
    guard version == AgentMeshConstants.agentInfoVersionV1 || version == AgentMeshConstants.agentInfoVersionV2 else { return nil }

    let roleLen = Int(data[offset])
    offset += 1
    guard offset + roleLen <= data.count else { return nil }
    let role = String(data: data[offset..<offset + roleLen], encoding: .utf8) ?? ""
    offset += roleLen

    guard offset < data.count else { return nil }
    let modelLen = Int(data[offset])
    offset += 1
    guard offset + modelLen <= data.count else { return nil }
    let model = String(data: data[offset..<offset + modelLen], encoding: .utf8) ?? ""
    offset += modelLen

    guard offset < data.count else { return nil }
    let quality = data[offset]
    offset += 1

    guard offset < data.count else {
        return AgentInfo(role: role, modelId: model, qualityScore: quality, modelHash: nil, paymentTerms: nil)
    }
    let hashLen = Int(data[offset])
    offset += 1
    guard offset + hashLen <= data.count else { return nil }
    let hash = String(data: data[offset..<offset + hashLen], encoding: .utf8)
    offset += hashLen

    if version == AgentMeshConstants.agentInfoVersionV1 {
        return AgentInfo(role: role, modelId: model, qualityScore: min(100, quality), modelHash: hash, paymentTerms: nil)
    }

    var paymentRail: String?
    var settlementMode: String?
    var requiresLocking: String?
    var unit: String?
    var priceModel: String?
    var pricePerRequest: UInt64?
    var pricePerInputToken: UInt64?
    var pricePerOutputToken: UInt64?
    var minDeposit: UInt64?
    var granularityTokens: UInt32?
    var acceptedMints: [String] = []
    var requestTTLSeconds: UInt32?
    var x402ChainID: UInt64?
    var x402TokenAddress: String?
    var x402PayTo: String?
    var x402GatewayURL: String?
    var x402Scheme: String?
    var x402FacilitatorID: String?

    while offset + 2 <= data.count {
        let typeRaw = data[offset]
        offset += 1
        let length = Int(data[offset])
        offset += 1

        guard offset + length <= data.count else { break }
        let value = data[offset..<offset + length]
        offset += length

        guard let type = AgentPaymentTermsTLV(rawValue: typeRaw) else { continue }
        switch type {
        case .paymentRail:
            paymentRail = String(data: value, encoding: .utf8)
        case .settlementMode:
            settlementMode = String(data: value, encoding: .utf8)
        case .unit:
            unit = String(data: value, encoding: .utf8)
        case .requiresLocking:
            requiresLocking = String(data: value, encoding: .utf8)
        case .priceModel:
            priceModel = String(data: value, encoding: .utf8)
        case .pricePerRequest:
            if value.count == 8 {
                pricePerRequest = value.reduce(UInt64(0)) { ($0 << 8) | UInt64($1) }
            }
        case .pricePerInputToken:
            if value.count == 8 {
                pricePerInputToken = value.reduce(UInt64(0)) { ($0 << 8) | UInt64($1) }
            }
        case .pricePerOutputToken:
            if value.count == 8 {
                pricePerOutputToken = value.reduce(UInt64(0)) { ($0 << 8) | UInt64($1) }
            }
        case .minDeposit:
            if value.count == 8 {
                minDeposit = value.reduce(UInt64(0)) { ($0 << 8) | UInt64($1) }
            }
        case .granularityTokens:
            if value.count == 4 {
                granularityTokens = value.reduce(UInt32(0)) { ($0 << 8) | UInt32($1) }
            }
        case .acceptedMint:
            if let mint = String(data: value, encoding: .utf8), !mint.isEmpty {
                acceptedMints.append(mint)
            }
        case .requestTTLSeconds:
            if value.count == 4 {
                requestTTLSeconds = value.reduce(UInt32(0)) { ($0 << 8) | UInt32($1) }
            }
        case .x402ChainID:
            if value.count == 8 {
                x402ChainID = value.reduce(UInt64(0)) { ($0 << 8) | UInt64($1) }
            }
        case .x402TokenAddress:
            x402TokenAddress = String(data: value, encoding: .utf8)
        case .x402PayTo:
            x402PayTo = String(data: value, encoding: .utf8)
        case .x402GatewayURL:
            x402GatewayURL = String(data: value, encoding: .utf8)
        case .x402Scheme:
            x402Scheme = String(data: value, encoding: .utf8)
        case .x402FacilitatorID:
            x402FacilitatorID = String(data: value, encoding: .utf8)
        }
    }

    var paymentTerms: AgentPaymentTerms?
    if let railRaw = paymentRail,
       let rail = AgentPaymentRail(rawValue: railRaw),
       let modeRaw = settlementMode,
       let mode = AgentSettlementMode(rawValue: modeRaw),
       let unit,
       let requestTTLSeconds {
        let parsedLocking = requiresLocking.flatMap { AgentPaymentLockingMode(rawValue: $0) } ?? .none
        let normalizedPricePerRequest = pricePerRequest ?? 0
        let parsedPriceModel = priceModel.flatMap { AgentPaymentPriceModel(rawValue: $0) }
        paymentTerms = AgentPaymentTerms(
            paymentRail: rail,
            settlementMode: mode,
            requiresLocking: parsedLocking,
            unit: unit,
            priceModel: parsedPriceModel,
            pricePerRequest: normalizedPricePerRequest,
            pricePerInputToken: pricePerInputToken,
            pricePerOutputToken: pricePerOutputToken,
            minDeposit: minDeposit,
            granularityTokens: granularityTokens,
            acceptedMints: acceptedMints,
            requestTTLSeconds: requestTTLSeconds,
            x402ChainID: x402ChainID,
            x402TokenAddress: x402TokenAddress,
            x402PayTo: x402PayTo,
            x402GatewayURL: x402GatewayURL,
            x402FacilitatorID: x402FacilitatorID,
            x402Scheme: x402Scheme.flatMap { AgentX402Scheme(rawValue: $0) }
        ).sanitized()
    }

    return AgentInfo(role: role, modelId: model, qualityScore: min(100, quality), modelHash: hash, paymentTerms: paymentTerms)
}

private func encodeAgentInfoV1(_ info: AgentInfo) -> Data {
    var data = Data()
    data.append(AgentMeshConstants.agentInfoVersionV1)
    let roleData = info.role.data(using: .utf8) ?? Data()
    let modelData = info.modelId.data(using: .utf8) ?? Data()
    let hashData = info.modelHash?.data(using: .utf8) ?? Data()

    data.append(UInt8(min(roleData.count, AgentMeshConstants.maxTLVStringBytes)))
    data.append(roleData.prefix(AgentMeshConstants.maxTLVStringBytes))
    data.append(UInt8(min(modelData.count, AgentMeshConstants.maxTLVStringBytes)))
    data.append(modelData.prefix(AgentMeshConstants.maxTLVStringBytes))
    data.append(min(info.qualityScore, 100))
    data.append(UInt8(min(hashData.count, AgentMeshConstants.maxTLVStringBytes)))
    data.append(hashData.prefix(AgentMeshConstants.maxTLVStringBytes))
    return data
}

private func appendAgentInfoPaymentTLV(_ type: AgentPaymentTermsTLV, string: String, into data: inout Data) {
    guard let payload = string.data(using: .utf8), payload.count <= AgentMeshConstants.maxTLVStringBytes else { return }
    data.append(type.rawValue)
    data.append(UInt8(payload.count))
    data.append(payload)
}

private func appendAgentInfoPaymentTLV(_ type: AgentPaymentTermsTLV, uint64: UInt64, into data: inout Data) {
    data.append(type.rawValue)
    data.append(8)
    var value = uint64.bigEndian
    withUnsafeBytes(of: &value) { data.append(contentsOf: $0) }
}

private func appendAgentInfoPaymentTLV(_ type: AgentPaymentTermsTLV, uint32: UInt32, into data: inout Data) {
    data.append(type.rawValue)
    data.append(4)
    var value = uint32.bigEndian
    withUnsafeBytes(of: &value) { data.append(contentsOf: $0) }
}

struct PrivateMessagePacket {
    let messageID: String
    let content: String

    private enum TLVType: UInt8 {
        case messageID = 0x00
        case content = 0x01
    }

    func encode() -> Data? {
        var data = Data()
        data.reserveCapacity(2 + min(messageID.count, 255) + 2 + min(content.count, 255))

        // TLV for messageID
        guard let messageIDData = messageID.data(using: .utf8), messageIDData.count <= 255 else { return nil }
        data.append(TLVType.messageID.rawValue)
        data.append(UInt8(messageIDData.count))
        data.append(messageIDData)

        // TLV for content
        guard let contentData = content.data(using: .utf8), contentData.count <= 255 else { return nil }
        data.append(TLVType.content.rawValue)
        data.append(UInt8(contentData.count))
        data.append(contentData)

        return data
    }

    static func decode(from data: Data) -> PrivateMessagePacket? {
        var offset = 0
        var messageID: String?
        var content: String?

        while offset + 2 <= data.count {
            guard let type = TLVType(rawValue: data[offset]) else { return nil }
            offset += 1

            let length = Int(data[offset])
            offset += 1

            guard offset + length <= data.count else { return nil }
            let value = data[offset..<offset + length]
            offset += length

            switch type {
            case .messageID:
                messageID = String(data: value, encoding: .utf8)
            case .content:
                content = String(data: value, encoding: .utf8)
            }
        }

        guard let messageID = messageID, let content = content else { return nil }
        return PrivateMessagePacket(messageID: messageID, content: content)
    }
}

struct AgentRequestPacket {
    let requestID: String
    let role: String
    let prompt: String
    let sessionID: String?
    let attachmentCount: UInt8?
    let senderAlias: String?
    let createdAtMs: UInt64?
    let ttlMs: UInt32?
    let quoteID: String?
    let quoteOptionID: String?

    init(
        requestID: String,
        role: String,
        prompt: String,
        sessionID: String?,
        attachmentCount: UInt8?,
        senderAlias: String?,
        createdAtMs: UInt64?,
        ttlMs: UInt32?,
        quoteID: String? = nil,
        quoteOptionID: String? = nil
    ) {
        self.requestID = requestID
        self.role = role
        self.prompt = prompt
        self.sessionID = sessionID
        self.attachmentCount = attachmentCount
        self.senderAlias = senderAlias
        self.createdAtMs = createdAtMs
        self.ttlMs = ttlMs
        self.quoteID = quoteID
        self.quoteOptionID = quoteOptionID
    }

    func encode() -> Data? {
        var data = Data()
        guard let idData = requestID.data(using: .utf8), idData.count <= AgentMeshConstants.maxTLVStringBytes else { return nil }
        guard let roleData = role.data(using: .utf8), roleData.count <= AgentMeshConstants.maxTLVStringBytes else { return nil }
        guard let promptData = prompt.data(using: .utf8), promptData.count <= 65535 else { return nil }

        data.append(AgentRequestTLV.requestID.rawValue)
        data.append(UInt8(idData.count))
        data.append(idData)

        data.append(AgentRequestTLV.role.rawValue)
        data.append(UInt8(roleData.count))
        data.append(roleData)

        data.append(AgentRequestTLV.prompt.rawValue)
        data.append(UInt8(min(promptData.count, AgentMeshConstants.maxTLVStringBytes)))
        data.append(promptData.prefix(AgentMeshConstants.maxTLVStringBytes))

        if let sessionID,
           let sessionData = sessionID.data(using: .utf8),
           sessionData.count <= AgentMeshConstants.maxTLVStringBytes {
            data.append(AgentRequestTLV.sessionID.rawValue)
            data.append(UInt8(sessionData.count))
            data.append(sessionData)
        }
        if let attachmentCount {
            data.append(AgentRequestTLV.attachmentCount.rawValue)
            data.append(1)
            data.append(attachmentCount)
        }
        if let senderAlias,
           let aliasData = senderAlias.data(using: .utf8),
           aliasData.count <= AgentMeshConstants.maxTLVStringBytes {
            data.append(AgentRequestTLV.senderAlias.rawValue)
            data.append(UInt8(aliasData.count))
            data.append(aliasData)
        }
        if let createdAtMs {
            data.append(AgentRequestTLV.createdAtMs.rawValue)
            data.append(8)
            var value = createdAtMs.bigEndian
            withUnsafeBytes(of: &value) { data.append(contentsOf: $0) }
        }
        if let ttlMs {
            data.append(AgentRequestTLV.ttlMs.rawValue)
            data.append(4)
            var value = ttlMs.bigEndian
            withUnsafeBytes(of: &value) { data.append(contentsOf: $0) }
        }
        if let quoteID,
           let quoteIDData = quoteID.data(using: .utf8),
           quoteIDData.count <= AgentMeshConstants.maxTLVStringBytes {
            data.append(AgentRequestTLV.quoteID.rawValue)
            data.append(UInt8(quoteIDData.count))
            data.append(quoteIDData)
        }
        if let quoteOptionID,
           let quoteOptionData = quoteOptionID.data(using: .utf8),
           quoteOptionData.count <= AgentMeshConstants.maxTLVStringBytes {
            data.append(AgentRequestTLV.quoteOptionID.rawValue)
            data.append(UInt8(quoteOptionData.count))
            data.append(quoteOptionData)
        }
        return data
    }

    static func decode(from data: Data) -> AgentRequestPacket? {
        var offset = 0
        var requestID: String?
        var role: String?
        var prompt: String?
        var sessionID: String?
        var attachmentCount: UInt8?
        var senderAlias: String?
        var createdAtMs: UInt64?
        var ttlMs: UInt32?
        var quoteID: String?
        var quoteOptionID: String?

        while offset + 2 <= data.count {
            let typeByte = data[offset]
            offset += 1
            let length = Int(data[offset])
            offset += 1
            guard offset + length <= data.count else { return nil }
            let value = data[offset..<offset + length]
            offset += length

            guard let type = AgentRequestTLV(rawValue: typeByte) else { continue }
            switch type {
            case .requestID:
                requestID = String(data: value, encoding: .utf8)
            case .role:
                role = String(data: value, encoding: .utf8)
            case .prompt:
                prompt = String(data: value, encoding: .utf8)
            case .sessionID:
                sessionID = String(data: value, encoding: .utf8)
            case .attachmentCount:
                attachmentCount = value.first
            case .senderAlias:
                senderAlias = String(data: value, encoding: .utf8)
            case .createdAtMs:
                if value.count == 8 {
                    createdAtMs = value.reduce(UInt64(0)) { ($0 << 8) | UInt64($1) }
                }
            case .ttlMs:
                if value.count == 4 {
                    ttlMs = value.reduce(UInt32(0)) { ($0 << 8) | UInt32($1) }
                }
            case .quoteID:
                quoteID = String(data: value, encoding: .utf8)
            case .quoteOptionID:
                quoteOptionID = String(data: value, encoding: .utf8)
            }
        }

        guard let requestID = requestID, let role = role, let prompt = prompt else { return nil }
        return AgentRequestPacket(
            requestID: requestID,
            role: role,
            prompt: prompt,
            sessionID: sessionID,
            attachmentCount: attachmentCount,
            senderAlias: senderAlias,
            createdAtMs: createdAtMs,
            ttlMs: ttlMs,
            quoteID: quoteID,
            quoteOptionID: quoteOptionID
        )
    }
}

struct AgentResponsePacket {
    let requestID: String
    let content: String
    let isError: Bool
    let sessionID: String?
    let chunkIndex: UInt16?
    let chunkTotal: UInt16?
    let paymentRequired: Bool
    let paymentRequest: String?
    let paymentError: String?

    init(
        requestID: String,
        content: String,
        isError: Bool,
        sessionID: String?,
        chunkIndex: UInt16?,
        chunkTotal: UInt16?,
        paymentRequired: Bool = false,
        paymentRequest: String? = nil,
        paymentError: String? = nil
    ) {
        self.requestID = requestID
        self.content = content
        self.isError = isError
        self.sessionID = sessionID
        self.chunkIndex = chunkIndex
        self.chunkTotal = chunkTotal
        self.paymentRequired = paymentRequired
        self.paymentRequest = paymentRequest
        self.paymentError = paymentError
    }

    func encode() -> Data? {
        var data = Data()
        guard let idData = requestID.data(using: .utf8), idData.count <= AgentMeshConstants.maxTLVStringBytes else { return nil }
        guard let contentData = content.data(using: .utf8), contentData.count <= 65535 else { return nil }

        data.append(AgentResponseTLV.requestID.rawValue)
        data.append(UInt8(idData.count))
        data.append(idData)

        data.append(AgentResponseTLV.content.rawValue)
        data.append(UInt8(min(contentData.count, AgentMeshConstants.maxTLVStringBytes)))
        data.append(contentData.prefix(AgentMeshConstants.maxTLVStringBytes))

        data.append(AgentResponseTLV.isError.rawValue)
        data.append(1)
        data.append(isError ? 1 : 0)

        if let sessionID,
           let sessionData = sessionID.data(using: .utf8),
           sessionData.count <= AgentMeshConstants.maxTLVStringBytes {
            data.append(AgentResponseTLV.sessionID.rawValue)
            data.append(UInt8(sessionData.count))
            data.append(sessionData)
        }

        if let chunkIndex {
            data.append(AgentResponseTLV.chunkIndex.rawValue)
            data.append(2)
            data.append(UInt8((chunkIndex >> 8) & 0xFF))
            data.append(UInt8(chunkIndex & 0xFF))
        }

        if let chunkTotal {
            data.append(AgentResponseTLV.chunkTotal.rawValue)
            data.append(2)
            data.append(UInt8((chunkTotal >> 8) & 0xFF))
            data.append(UInt8(chunkTotal & 0xFF))
        }

        if paymentRequired {
            data.append(AgentResponseTLV.paymentRequired.rawValue)
            data.append(1)
            data.append(1)
        }

        if let paymentRequest,
           let requestData = paymentRequest.data(using: .utf8),
           requestData.count <= AgentMeshConstants.maxTLVStringBytes {
            data.append(AgentResponseTLV.paymentRequest.rawValue)
            data.append(UInt8(requestData.count))
            data.append(requestData)
        }

        if let paymentError,
           let errorData = paymentError.data(using: .utf8),
           errorData.count <= AgentMeshConstants.maxTLVStringBytes {
            data.append(AgentResponseTLV.paymentError.rawValue)
            data.append(UInt8(errorData.count))
            data.append(errorData)
        }
        return data
    }

    static func decode(from data: Data) -> AgentResponsePacket? {
        var offset = 0
        var requestID: String?
        var content: String?
        var isError = false
        var sessionID: String?
        var chunkIndex: UInt16?
        var chunkTotal: UInt16?
        var paymentRequired = false
        var paymentRequest: String?
        var paymentError: String?

        while offset + 2 <= data.count {
            let typeByte = data[offset]
            offset += 1
            let length = Int(data[offset])
            offset += 1
            guard offset + length <= data.count else { return nil }
            let value = data[offset..<offset + length]
            offset += length

            guard let type = AgentResponseTLV(rawValue: typeByte) else { continue }
            switch type {
            case .requestID:
                requestID = String(data: value, encoding: .utf8)
            case .content:
                content = String(data: value, encoding: .utf8)
            case .isError:
                isError = value.first == 1
            case .sessionID:
                sessionID = String(data: value, encoding: .utf8)
            case .chunkIndex:
                if value.count == 2 {
                    let hi = UInt16(value[value.startIndex])
                    let lo = UInt16(value[value.index(after: value.startIndex)])
                    chunkIndex = (hi << 8) | lo
                }
            case .chunkTotal:
                if value.count == 2 {
                    let hi = UInt16(value[value.startIndex])
                    let lo = UInt16(value[value.index(after: value.startIndex)])
                    chunkTotal = (hi << 8) | lo
                }
            case .paymentRequired:
                paymentRequired = value.first == 1
            case .paymentRequest:
                paymentRequest = String(data: value, encoding: .utf8)
            case .paymentError:
                paymentError = String(data: value, encoding: .utf8)
            }
        }

        guard let requestID = requestID, let content = content else { return nil }
        return AgentResponsePacket(
            requestID: requestID,
            content: content,
            isError: isError,
            sessionID: sessionID,
            chunkIndex: chunkIndex,
            chunkTotal: chunkTotal,
            paymentRequired: paymentRequired,
            paymentRequest: paymentRequest,
            paymentError: paymentError
        )
    }
}

struct AgentResponseChunkPacket {
    let requestID: String
    let index: UInt16
    let isFinal: Bool
    let content: String
    let isError: Bool
    let sessionID: String?

    func encode() -> Data? {
        var data = Data()
        guard let idData = requestID.data(using: .utf8), idData.count <= AgentMeshConstants.maxTLVStringBytes else { return nil }
        guard let contentData = content.data(using: .utf8), contentData.count <= 65535 else { return nil }

        data.append(AgentResponseChunkTLV.requestID.rawValue)
        data.append(UInt8(idData.count))
        data.append(idData)

        data.append(AgentResponseChunkTLV.content.rawValue)
        data.append(UInt8(min(contentData.count, AgentMeshConstants.maxTLVStringBytes)))
        data.append(contentData.prefix(AgentMeshConstants.maxTLVStringBytes))

        data.append(AgentResponseChunkTLV.isError.rawValue)
        data.append(1)
        data.append(isError ? 1 : 0)

        if let sessionID,
           let sessionData = sessionID.data(using: .utf8),
           sessionData.count <= AgentMeshConstants.maxTLVStringBytes {
            data.append(AgentResponseChunkTLV.sessionID.rawValue)
            data.append(UInt8(sessionData.count))
            data.append(sessionData)
        }

        data.append(AgentResponseChunkTLV.index.rawValue)
        data.append(2)
        data.append(UInt8((index >> 8) & 0xFF))
        data.append(UInt8(index & 0xFF))

        data.append(AgentResponseChunkTLV.isFinal.rawValue)
        data.append(1)
        data.append(isFinal ? 1 : 0)

        return data
    }

    static func decode(from data: Data) -> AgentResponseChunkPacket? {
        var offset = 0
        var requestID: String?
        var content: String?
        var isError = false
        var sessionID: String?
        var index: UInt16?
        var isFinal = false

        while offset + 2 <= data.count {
            let typeByte = data[offset]
            offset += 1
            let length = Int(data[offset])
            offset += 1
            guard offset + length <= data.count else { return nil }
            let value = data[offset..<offset + length]
            offset += length

            guard let type = AgentResponseChunkTLV(rawValue: typeByte) else { continue }
            switch type {
            case .requestID:
                requestID = String(data: value, encoding: .utf8)
            case .content:
                content = String(data: value, encoding: .utf8)
            case .isError:
                isError = value.first == 1
            case .sessionID:
                sessionID = String(data: value, encoding: .utf8)
            case .index:
                if value.count == 2 {
                    let hi = UInt16(value[value.startIndex])
                    let lo = UInt16(value[value.index(after: value.startIndex)])
                    index = (hi << 8) | lo
                }
            case .isFinal:
                isFinal = value.first == 1
            }
        }

        guard let requestID = requestID, let content = content, let index = index else { return nil }
        return AgentResponseChunkPacket(
            requestID: requestID,
            index: index,
            isFinal: isFinal,
            content: content,
            isError: isError,
            sessionID: sessionID
        )
    }
}

struct AgentQuoteOption: Codable, Equatable {
    let optionID: String
    let label: String
    let waitSeconds: UInt16
    let discountBps: UInt16
    let estimatedPrice: UInt64
    let paymentRail: AgentPaymentRail
    let unit: String
    let settlementMode: AgentSettlementMode
    let requiresLocking: AgentPaymentLockingMode?
    let acceptedMints: [String]
    let requestTTLSeconds: UInt32
    let chainID: UInt64?
    let tokenAddress: String?
    let qualityScore: UInt8
    let modelId: String
    let modelHash: String?

    private enum CodingKeys: String, CodingKey {
        case optionID
        case label
        case waitSeconds
        case discountBps
        case estimatedPrice
        case paymentRail
        case unit
        case settlementMode
        case requiresLocking
        case acceptedMints
        case requestTTLSeconds
        case chainID
        case tokenAddress
        case qualityScore
        case modelId
        case modelHash
    }

    init(
        optionID: String,
        label: String,
        waitSeconds: UInt16,
        discountBps: UInt16,
        estimatedPrice: UInt64,
        paymentRail: AgentPaymentRail = .cashu,
        unit: String,
        settlementMode: AgentSettlementMode,
        requiresLocking: AgentPaymentLockingMode? = nil,
        acceptedMints: [String],
        requestTTLSeconds: UInt32,
        chainID: UInt64? = nil,
        tokenAddress: String? = nil,
        qualityScore: UInt8,
        modelId: String,
        modelHash: String?
    ) {
        self.optionID = optionID
        self.label = label
        self.waitSeconds = waitSeconds
        self.discountBps = discountBps
        self.estimatedPrice = estimatedPrice
        self.paymentRail = paymentRail
        self.unit = unit
        self.settlementMode = settlementMode
        self.requiresLocking = requiresLocking
        self.acceptedMints = acceptedMints
        self.requestTTLSeconds = requestTTLSeconds
        self.chainID = chainID
        self.tokenAddress = tokenAddress
        self.qualityScore = qualityScore
        self.modelId = modelId
        self.modelHash = modelHash
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        optionID = try container.decode(String.self, forKey: .optionID)
        label = try container.decode(String.self, forKey: .label)
        waitSeconds = try container.decode(UInt16.self, forKey: .waitSeconds)
        discountBps = try container.decode(UInt16.self, forKey: .discountBps)
        estimatedPrice = try container.decode(UInt64.self, forKey: .estimatedPrice)
        paymentRail = try container.decodeIfPresent(AgentPaymentRail.self, forKey: .paymentRail) ?? .cashu
        unit = try container.decode(String.self, forKey: .unit)
        settlementMode = try container.decode(AgentSettlementMode.self, forKey: .settlementMode)
        requiresLocking = try container.decodeIfPresent(AgentPaymentLockingMode.self, forKey: .requiresLocking)
        acceptedMints = try container.decodeIfPresent([String].self, forKey: .acceptedMints) ?? []
        requestTTLSeconds = try container.decode(UInt32.self, forKey: .requestTTLSeconds)
        chainID = try container.decodeIfPresent(UInt64.self, forKey: .chainID)
        tokenAddress = try container.decodeIfPresent(String.self, forKey: .tokenAddress)
        qualityScore = min(100, try container.decode(UInt8.self, forKey: .qualityScore))
        modelId = try container.decode(String.self, forKey: .modelId)
        modelHash = try container.decodeIfPresent(String.self, forKey: .modelHash)
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(optionID, forKey: .optionID)
        try container.encode(label, forKey: .label)
        try container.encode(waitSeconds, forKey: .waitSeconds)
        try container.encode(discountBps, forKey: .discountBps)
        try container.encode(estimatedPrice, forKey: .estimatedPrice)
        try container.encode(paymentRail, forKey: .paymentRail)
        try container.encode(unit, forKey: .unit)
        try container.encode(settlementMode, forKey: .settlementMode)
        try container.encodeIfPresent(requiresLocking, forKey: .requiresLocking)
        try container.encode(acceptedMints, forKey: .acceptedMints)
        try container.encode(requestTTLSeconds, forKey: .requestTTLSeconds)
        try container.encodeIfPresent(chainID, forKey: .chainID)
        try container.encodeIfPresent(tokenAddress, forKey: .tokenAddress)
        try container.encode(min(100, qualityScore), forKey: .qualityScore)
        try container.encode(modelId, forKey: .modelId)
        try container.encodeIfPresent(modelHash, forKey: .modelHash)
    }
}

struct AgentQuoteRequestPacket {
    let quoteID: String
    let role: String
    let prompt: String
    let estimatedInputTokens: UInt32?
    let estimatedOutputTokens: UInt32?
    let sentAt: UInt64
    let maxOptions: UInt8

    func encode() -> Data? {
        guard let quoteIDData = quoteID.data(using: .utf8),
              let roleData = role.data(using: .utf8),
              let promptData = prompt.data(using: .utf8) else { return nil }
        var data = Data()
        guard appendTLV16(type: AgentQuoteRequestTLV.quoteID.rawValue, value: quoteIDData, into: &data) else { return nil }
        guard appendTLV16(type: AgentQuoteRequestTLV.role.rawValue, value: roleData, into: &data) else { return nil }
        guard appendTLV16(type: AgentQuoteRequestTLV.prompt.rawValue, value: promptData, into: &data) else { return nil }

        if let estimatedInputTokens {
            var value = estimatedInputTokens.bigEndian
            let tokenData = withUnsafeBytes(of: &value) { Data($0) }
            guard appendTLV16(type: AgentQuoteRequestTLV.estimatedInputTokens.rawValue, value: tokenData, into: &data) else { return nil }
        }
        if let estimatedOutputTokens {
            var value = estimatedOutputTokens.bigEndian
            let tokenData = withUnsafeBytes(of: &value) { Data($0) }
            guard appendTLV16(type: AgentQuoteRequestTLV.estimatedOutputTokens.rawValue, value: tokenData, into: &data) else { return nil }
        }

        var sentAtValue = sentAt.bigEndian
        let sentAtData = withUnsafeBytes(of: &sentAtValue) { Data($0) }
        guard appendTLV16(type: AgentQuoteRequestTLV.sentAt.rawValue, value: sentAtData, into: &data) else { return nil }
        guard appendTLV16(type: AgentQuoteRequestTLV.maxOptions.rawValue, value: Data([max(1, maxOptions)]), into: &data) else { return nil }
        return data
    }

    static func decode(from data: Data) -> AgentQuoteRequestPacket? {
        var quoteID: String?
        var role: String?
        var prompt: String?
        var estimatedInputTokens: UInt32?
        var estimatedOutputTokens: UInt32?
        var sentAt: UInt64?
        var maxOptions: UInt8 = 3

        if !decodeTLV16(data, apply: { typeRaw, value in
            guard let type = AgentQuoteRequestTLV(rawValue: typeRaw) else { return }
            switch type {
            case .quoteID:
                quoteID = String(data: value, encoding: .utf8)
            case .role:
                role = String(data: value, encoding: .utf8)
            case .prompt:
                prompt = String(data: value, encoding: .utf8)
            case .estimatedInputTokens:
                if value.count == 4 {
                    estimatedInputTokens = value.reduce(UInt32(0)) { ($0 << 8) | UInt32($1) }
                }
            case .estimatedOutputTokens:
                if value.count == 4 {
                    estimatedOutputTokens = value.reduce(UInt32(0)) { ($0 << 8) | UInt32($1) }
                }
            case .sentAt:
                if value.count == 8 {
                    sentAt = value.reduce(UInt64(0)) { ($0 << 8) | UInt64($1) }
                }
            case .maxOptions:
                maxOptions = max(1, value.first ?? 3)
            }
        }) { return nil }

        guard let quoteID, let role, let prompt, let sentAt else { return nil }
        return AgentQuoteRequestPacket(
            quoteID: quoteID,
            role: role,
            prompt: prompt,
            estimatedInputTokens: estimatedInputTokens,
            estimatedOutputTokens: estimatedOutputTokens,
            sentAt: sentAt,
            maxOptions: maxOptions
        )
    }
}

struct AgentQuoteResponsePacket {
    let quoteID: String
    let role: String
    let options: [AgentQuoteOption]
    let expiresAt: UInt64
    let error: String?

    func encode() -> Data? {
        guard let quoteIDData = quoteID.data(using: .utf8),
              let roleData = role.data(using: .utf8) else { return nil }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        guard let optionsData = try? encoder.encode(options) else { return nil }

        var data = Data()
        guard appendTLV16(type: AgentQuoteResponseTLV.quoteID.rawValue, value: quoteIDData, into: &data) else { return nil }
        guard appendTLV16(type: AgentQuoteResponseTLV.role.rawValue, value: roleData, into: &data) else { return nil }
        guard appendTLV16(type: AgentQuoteResponseTLV.optionsJSON.rawValue, value: optionsData, into: &data) else { return nil }

        var expiresAtValue = expiresAt.bigEndian
        let expiresAtData = withUnsafeBytes(of: &expiresAtValue) { Data($0) }
        guard appendTLV16(type: AgentQuoteResponseTLV.expiresAt.rawValue, value: expiresAtData, into: &data) else { return nil }

        if let error,
           let errorData = error.data(using: .utf8) {
            guard appendTLV16(type: AgentQuoteResponseTLV.error.rawValue, value: errorData, into: &data) else { return nil }
        }

        return data
    }

    static func decode(from data: Data) -> AgentQuoteResponsePacket? {
        var quoteID: String?
        var role: String?
        var options: [AgentQuoteOption] = []
        var expiresAt: UInt64?
        var error: String?

        if !decodeTLV16(data, apply: { typeRaw, value in
            guard let type = AgentQuoteResponseTLV(rawValue: typeRaw) else { return }
            switch type {
            case .quoteID:
                quoteID = String(data: value, encoding: .utf8)
            case .role:
                role = String(data: value, encoding: .utf8)
            case .optionsJSON:
                options = (try? JSONDecoder().decode([AgentQuoteOption].self, from: value)) ?? []
            case .expiresAt:
                if value.count == 8 {
                    expiresAt = value.reduce(UInt64(0)) { ($0 << 8) | UInt64($1) }
                }
            case .error:
                error = String(data: value, encoding: .utf8)
            }
        }) { return nil }

        guard let quoteID, let role, let expiresAt else { return nil }
        return AgentQuoteResponsePacket(
            quoteID: quoteID,
            role: role,
            options: options,
            expiresAt: expiresAt,
            error: error
        )
    }
}

enum AgentPaymentReceiptStatus: String, Codable, CaseIterable {
    case acceptedOffline = "accepted_offline"
    case finalizedOnline = "finalized_online"
    case rejected
}

struct AgentPaymentPayloadPacket {
    let requestID: String
    let sessionID: String?
    let rail: String
    let payload: String
    let sentAt: UInt64
    let clientNonce: String

    func encode() -> Data? {
        guard let requestIDData = requestID.data(using: .utf8),
              let railData = rail.data(using: .utf8),
              let payloadData = payload.data(using: .utf8),
              let nonceData = clientNonce.data(using: .utf8) else { return nil }

        var data = Data()
        guard appendTLV16(type: AgentPaymentPayloadTLV.requestID.rawValue, value: requestIDData, into: &data) else { return nil }
        if let sessionID, let sessionData = sessionID.data(using: .utf8) {
            guard appendTLV16(type: AgentPaymentPayloadTLV.sessionID.rawValue, value: sessionData, into: &data) else { return nil }
        }
        guard appendTLV16(type: AgentPaymentPayloadTLV.rail.rawValue, value: railData, into: &data) else { return nil }
        guard appendTLV16(type: AgentPaymentPayloadTLV.payload.rawValue, value: payloadData, into: &data) else { return nil }
        guard appendTLV16(type: AgentPaymentPayloadTLV.clientNonce.rawValue, value: nonceData, into: &data) else { return nil }

        var sentAtValue = sentAt.bigEndian
        let sentAtData = withUnsafeBytes(of: &sentAtValue) { Data($0) }
        guard appendTLV16(type: AgentPaymentPayloadTLV.sentAt.rawValue, value: sentAtData, into: &data) else { return nil }
        return data
    }

    static func decode(from data: Data) -> AgentPaymentPayloadPacket? {
        var requestID: String?
        var sessionID: String?
        var rail: String?
        var payload: String?
        var sentAt: UInt64?
        var clientNonce: String?

        if !decodeTLV16(data, apply: { typeRaw, value in
            guard let type = AgentPaymentPayloadTLV(rawValue: typeRaw) else { return }
            switch type {
            case .requestID:
                requestID = String(data: value, encoding: .utf8)
            case .sessionID:
                sessionID = String(data: value, encoding: .utf8)
            case .rail:
                rail = String(data: value, encoding: .utf8)
            case .payload:
                payload = String(data: value, encoding: .utf8)
            case .sentAt:
                if value.count == 8 {
                    sentAt = value.reduce(UInt64(0)) { ($0 << 8) | UInt64($1) }
                }
            case .clientNonce:
                clientNonce = String(data: value, encoding: .utf8)
            }
        }) { return nil }

        guard let requestID, let rail, let payload, let sentAt, let clientNonce else { return nil }
        return AgentPaymentPayloadPacket(
            requestID: requestID,
            sessionID: sessionID,
            rail: rail,
            payload: payload,
            sentAt: sentAt,
            clientNonce: clientNonce
        )
    }
}

struct AgentPaymentReceiptPacket {
    let requestID: String
    let sessionID: String?
    let paymentID: String?
    let status: AgentPaymentReceiptStatus
    let details: String?
    let nullifiers: [String]
    let notaryReceipts: [String]
    let fairUnlockKey: String?

    init(
        requestID: String,
        sessionID: String?,
        paymentID: String?,
        status: AgentPaymentReceiptStatus,
        details: String?,
        nullifiers: [String],
        notaryReceipts: [String],
        fairUnlockKey: String? = nil
    ) {
        self.requestID = requestID
        self.sessionID = sessionID
        self.paymentID = paymentID
        self.status = status
        self.details = details
        self.nullifiers = nullifiers
        self.notaryReceipts = notaryReceipts
        self.fairUnlockKey = fairUnlockKey
    }

    func encode() -> Data? {
        guard let requestIDData = requestID.data(using: .utf8),
              let statusData = status.rawValue.data(using: .utf8) else { return nil }

        var data = Data()
        guard appendTLV16(type: AgentPaymentReceiptTLV.requestID.rawValue, value: requestIDData, into: &data) else { return nil }
        if let sessionID, let sessionData = sessionID.data(using: .utf8) {
            guard appendTLV16(type: AgentPaymentReceiptTLV.sessionID.rawValue, value: sessionData, into: &data) else { return nil }
        }
        if let paymentID, let paymentIDData = paymentID.data(using: .utf8) {
            guard appendTLV16(type: AgentPaymentReceiptTLV.paymentID.rawValue, value: paymentIDData, into: &data) else { return nil }
        }
        guard appendTLV16(type: AgentPaymentReceiptTLV.status.rawValue, value: statusData, into: &data) else { return nil }
        if let details, let detailsData = details.data(using: .utf8) {
            guard appendTLV16(type: AgentPaymentReceiptTLV.details.rawValue, value: detailsData, into: &data) else { return nil }
        }
        for nullifier in nullifiers {
            guard let nullifierData = nullifier.data(using: .utf8) else { continue }
            guard appendTLV16(type: AgentPaymentReceiptTLV.nullifier.rawValue, value: nullifierData, into: &data) else { return nil }
        }
        for receipt in notaryReceipts {
            guard let receiptData = receipt.data(using: .utf8) else { continue }
            guard appendTLV16(type: AgentPaymentReceiptTLV.notaryReceipt.rawValue, value: receiptData, into: &data) else { return nil }
        }
        if let fairUnlockKey, let unlockData = fairUnlockKey.data(using: .utf8) {
            guard appendTLV16(type: AgentPaymentReceiptTLV.fairUnlockKey.rawValue, value: unlockData, into: &data) else { return nil }
        }
        return data
    }

    static func decode(from data: Data) -> AgentPaymentReceiptPacket? {
        var requestID: String?
        var sessionID: String?
        var paymentID: String?
        var status: AgentPaymentReceiptStatus?
        var details: String?
        var nullifiers: [String] = []
        var notaryReceipts: [String] = []
        var fairUnlockKey: String?

        if !decodeTLV16(data, apply: { typeRaw, value in
            guard let type = AgentPaymentReceiptTLV(rawValue: typeRaw) else { return }
            switch type {
            case .requestID:
                requestID = String(data: value, encoding: .utf8)
            case .sessionID:
                sessionID = String(data: value, encoding: .utf8)
            case .paymentID:
                paymentID = String(data: value, encoding: .utf8)
            case .status:
                if let raw = String(data: value, encoding: .utf8),
                   let parsed = AgentPaymentReceiptStatus(rawValue: raw) {
                    status = parsed
                }
            case .details:
                details = String(data: value, encoding: .utf8)
            case .nullifier:
                if let parsed = String(data: value, encoding: .utf8) {
                    nullifiers.append(parsed)
                }
            case .notaryReceipt:
                if let parsed = String(data: value, encoding: .utf8) {
                    notaryReceipts.append(parsed)
                }
            case .fairUnlockKey:
                fairUnlockKey = String(data: value, encoding: .utf8)
            }
        }) { return nil }

        guard let requestID, let status else { return nil }
        return AgentPaymentReceiptPacket(
            requestID: requestID,
            sessionID: sessionID,
            paymentID: paymentID,
            status: status,
            details: details,
            nullifiers: nullifiers,
            notaryReceipts: notaryReceipts,
            fairUnlockKey: fairUnlockKey
        )
    }
}

enum MintProxyMethod: String, Codable, CaseIterable {
    case info
    case keysets
    case swap
    case checkstate
    case relock
}

struct MintProxyRequestPacket {
    let proxyID: String
    let mintURL: String
    let method: MintProxyMethod
    let body: String
    let sentAt: UInt64

    func encode() -> Data? {
        guard let proxyIDData = proxyID.data(using: .utf8),
              let mintURLData = mintURL.data(using: .utf8),
              let methodData = method.rawValue.data(using: .utf8),
              let bodyData = body.data(using: .utf8) else { return nil }

        var data = Data()
        guard appendTLV16(type: MintProxyRequestTLV.proxyID.rawValue, value: proxyIDData, into: &data) else { return nil }
        guard appendTLV16(type: MintProxyRequestTLV.mintURL.rawValue, value: mintURLData, into: &data) else { return nil }
        guard appendTLV16(type: MintProxyRequestTLV.method.rawValue, value: methodData, into: &data) else { return nil }
        guard appendTLV16(type: MintProxyRequestTLV.body.rawValue, value: bodyData, into: &data) else { return nil }
        var sentAtValue = sentAt.bigEndian
        let sentAtData = withUnsafeBytes(of: &sentAtValue) { Data($0) }
        guard appendTLV16(type: MintProxyRequestTLV.sentAt.rawValue, value: sentAtData, into: &data) else { return nil }
        return data
    }

    static func decode(from data: Data) -> MintProxyRequestPacket? {
        var proxyID: String?
        var mintURL: String?
        var method: MintProxyMethod?
        var body: String?
        var sentAt: UInt64?

        if !decodeTLV16(data, apply: { typeRaw, value in
            guard let type = MintProxyRequestTLV(rawValue: typeRaw) else { return }
            switch type {
            case .proxyID:
                proxyID = String(data: value, encoding: .utf8)
            case .mintURL:
                mintURL = String(data: value, encoding: .utf8)
            case .method:
                if let raw = String(data: value, encoding: .utf8),
                   let parsed = MintProxyMethod(rawValue: raw) {
                    method = parsed
                }
            case .body:
                body = String(data: value, encoding: .utf8)
            case .sentAt:
                if value.count == 8 {
                    sentAt = value.reduce(UInt64(0)) { ($0 << 8) | UInt64($1) }
                }
            }
        }) { return nil }

        guard let proxyID, let mintURL, let method, let body, let sentAt else { return nil }
        return MintProxyRequestPacket(proxyID: proxyID, mintURL: mintURL, method: method, body: body, sentAt: sentAt)
    }
}

struct MintProxyResponsePacket {
    let proxyID: String
    let ok: Bool
    let body: String?
    let error: String?

    func encode() -> Data? {
        guard let proxyIDData = proxyID.data(using: .utf8) else { return nil }
        var data = Data()
        guard appendTLV16(type: MintProxyResponseTLV.proxyID.rawValue, value: proxyIDData, into: &data) else { return nil }
        guard appendTLV16(type: MintProxyResponseTLV.ok.rawValue, value: Data([ok ? 1 : 0]), into: &data) else { return nil }
        if let body, let bodyData = body.data(using: .utf8) {
            guard appendTLV16(type: MintProxyResponseTLV.body.rawValue, value: bodyData, into: &data) else { return nil }
        }
        if let error, let errorData = error.data(using: .utf8) {
            guard appendTLV16(type: MintProxyResponseTLV.error.rawValue, value: errorData, into: &data) else { return nil }
        }
        return data
    }

    static func decode(from data: Data) -> MintProxyResponsePacket? {
        var proxyID: String?
        var ok: Bool?
        var body: String?
        var error: String?

        if !decodeTLV16(data, apply: { typeRaw, value in
            guard let type = MintProxyResponseTLV(rawValue: typeRaw) else { return }
            switch type {
            case .proxyID:
                proxyID = String(data: value, encoding: .utf8)
            case .ok:
                ok = value.first == 1
            case .body:
                body = String(data: value, encoding: .utf8)
            case .error:
                error = String(data: value, encoding: .utf8)
            }
        }) { return nil }

        guard let proxyID, let ok else { return nil }
        return MintProxyResponsePacket(proxyID: proxyID, ok: ok, body: body, error: error)
    }
}

@inline(__always)
private func appendTLV16(type: UInt8, value: Data, into data: inout Data) -> Bool {
    guard value.count <= Int(UInt16.max) else { return false }
    data.append(type)
    var length = UInt16(value.count).bigEndian
    withUnsafeBytes(of: &length) { data.append(contentsOf: $0) }
    data.append(value)
    return true
}

private func decodeTLV16(_ data: Data, apply: (_ type: UInt8, _ value: Data) -> Void) -> Bool {
    var offset = 0
    while offset + 3 <= data.count {
        let type = data[offset]
        offset += 1
        let length = (UInt16(data[offset]) << 8) | UInt16(data[offset + 1])
        offset += 2
        let intLength = Int(length)
        guard offset + intLength <= data.count else { return false }
        let value = Data(data[offset..<offset + intLength])
        offset += intLength
        apply(type, value)
    }
    return offset == data.count
}
