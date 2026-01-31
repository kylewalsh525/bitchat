import Foundation

// MARK: - Protocol TLV Packets

struct AnnouncementPacket {
    let nickname: String
    let noisePublicKey: Data            // Noise static public key (Curve25519.KeyAgreement)
    let signingPublicKey: Data          // Ed25519 public key for signing
    let directNeighbors: [Data]?        // 8-byte peer IDs
    let agentInfo: AgentInfo?           // Optional agent capability info

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
    var data = Data()
    // Simple versioned layout:
    // [version:1][roleLen:1][role][modelLen:1][model][quality:1][hashLen:1][hash]
    data.append(AgentMeshConstants.agentInfoVersion)
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

func decodeAgentInfo(_ data: Data) -> AgentInfo? {
    var offset = 0
    guard data.count >= 6 else { return nil }
    let version = data[offset]
    offset += 1
    guard version == AgentMeshConstants.agentInfoVersion else { return nil }

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
        return AgentInfo(role: role, modelId: model, qualityScore: quality, modelHash: nil)
    }
    let hashLen = Int(data[offset])
    offset += 1
    guard offset + hashLen <= data.count else { return nil }
    let hash = String(data: data[offset..<offset + hashLen], encoding: .utf8)

    return AgentInfo(role: role, modelId: model, qualityScore: min(100, quality), modelHash: hash)
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
            ttlMs: ttlMs
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
            }
        }

        guard let requestID = requestID, let content = content else { return nil }
        return AgentResponsePacket(
            requestID: requestID,
            content: content,
            isError: isError,
            sessionID: sessionID,
            chunkIndex: chunkIndex,
            chunkTotal: chunkTotal
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
