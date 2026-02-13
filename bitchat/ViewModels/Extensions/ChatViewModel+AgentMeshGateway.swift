import Foundation

enum MintGatewayProxyError: LocalizedError {
    case unavailable
    case gatewayDisabled
    case noGatewayPeer
    case timeout
    case cancelled(String)
    case remoteRejected(String)

    var errorDescription: String? {
        switch self {
        case .unavailable:
            return "mint gateway is unavailable"
        case .gatewayDisabled:
            return "mint gateway is disabled"
        case .noGatewayPeer:
            return "no reachable mint gateway peer"
        case .timeout:
            return "mint gateway response timed out"
        case .cancelled(let reason):
            return reason
        case .remoteRejected(let reason):
            return reason
        }
    }
}

extension ChatViewModel {
    @MainActor
    func setupMintGatewayProxyLifecycle() {
        cashuMintClient.configureProxyRequestHandler { [weak self] request in
            guard let self else {
                throw MintGatewayProxyError.unavailable
            }
            return try await self.requestMintProxyViaMesh(request)
        }
    }

    @MainActor
    func cancelPendingMintProxyResponses(reason: String) {
        guard !pendingMintProxyResponses.isEmpty else { return }
        let pending = pendingMintProxyResponses
        pendingMintProxyResponses.removeAll()
        for (_, entry) in pending {
            entry.continuation.resume(throwing: MintGatewayProxyError.cancelled(reason))
        }
    }

    @MainActor
    func requestMintProxyViaMesh(_ request: MintProxyRequestPacket) async throws -> MintProxyResponsePacket {
        guard agentMeshFlags.enableGateway else {
            throw MintGatewayProxyError.gatewayDisabled
        }

        let proxyID = request.proxyID.trimmingCharacters(in: .whitespacesAndNewlines)
        let outgoingRequest: MintProxyRequestPacket
        if proxyID.isEmpty {
            outgoingRequest = MintProxyRequestPacket(
                proxyID: UUID().uuidString,
                mintURL: request.mintURL,
                method: request.method,
                body: request.body,
                sentAt: request.sentAt
            )
        } else {
            outgoingRequest = request
        }

        let candidates = mintGatewayCandidates()
        guard !candidates.isEmpty else {
            throw MintGatewayProxyError.noGatewayPeer
        }

        let maxAttempts = max(1, TransportConfig.mintProxyMaxCandidateAttempts)
        var lastError: Error = MintGatewayProxyError.noGatewayPeer
        for peerID in candidates.prefix(maxAttempts) {
            do {
                return try await requestMintProxyViaPeer(outgoingRequest, peerID: peerID)
            } catch {
                lastError = error
            }
        }
        throw lastError
    }

    @MainActor
    func handleMintProxyRequest(_ request: MintProxyRequestPacket, from peerID: PeerID) {
        guard agentMeshFlags.enableGateway else {
            let response = MintProxyResponsePacket(
                proxyID: request.proxyID,
                ok: false,
                body: nil,
                error: MintGatewayProxyError.gatewayDisabled.localizedDescription
            )
            meshService.sendMintProxyResponse(response, to: peerID)
            return
        }
        if isPeerBlocked(peerID) {
            return
        }

        Task { [weak self] in
            guard let self else { return }
            let response = await self.mintGatewayService.handle(request)
            await MainActor.run {
                self.meshService.sendMintProxyResponse(response, to: peerID)
            }
        }
    }

    @MainActor
    func handleMintProxyResponse(_ response: MintProxyResponsePacket, from peerID: PeerID) {
        guard let pending = pendingMintProxyResponses[response.proxyID] else { return }
        guard pending.peerID == peerID else { return }

        pendingMintProxyResponses.removeValue(forKey: response.proxyID)
        if response.ok {
            pending.continuation.resume(returning: response)
            return
        }
        pending.continuation.resume(
            throwing: MintGatewayProxyError.remoteRejected(
                response.error ?? "mint gateway rejected request"
            )
        )
    }

    @MainActor
    private func requestMintProxyViaPeer(_ request: MintProxyRequestPacket, peerID: PeerID) async throws -> MintProxyResponsePacket {
        if pendingMintProxyResponses[request.proxyID] != nil {
            throw MintGatewayProxyError.cancelled("duplicate pending proxy request")
        }

        let timeoutNs = UInt64(TransportConfig.mintProxyRequestTimeoutSeconds * 1_000_000_000)
        return try await withCheckedThrowingContinuation { continuation in
            pendingMintProxyResponses[request.proxyID] = PendingMintProxyResponse(
                peerID: peerID,
                continuation: continuation
            )
            meshService.sendMintProxyRequest(request, to: peerID)

            Task { [weak self] in
                try? await Task.sleep(nanoseconds: timeoutNs)
                await MainActor.run {
                    guard let self,
                          let pending = self.pendingMintProxyResponses[request.proxyID],
                          pending.peerID == peerID else { return }
                    self.pendingMintProxyResponses.removeValue(forKey: request.proxyID)
                    pending.continuation.resume(throwing: MintGatewayProxyError.timeout)
                }
            }
        }
    }

    @MainActor
    private func mintGatewayCandidates() -> [PeerID] {
        var candidateIDs: [PeerID] = []
        candidateIDs.reserveCapacity(allPeers.count)

        func appendCandidate(_ peerID: PeerID, connected: Bool, reachable: Bool) {
            if isPeerBlocked(peerID) {
                return
            }
            if !connected && !reachable {
                return
            }
            if !candidateIDs.contains(peerID) {
                candidateIDs.append(peerID)
            }
        }

        for snapshot in meshService.currentPeerSnapshots() {
            let peerID = snapshot.peerID
            let connected = snapshot.isConnected || meshService.isPeerConnected(peerID)
            let reachable = connected || meshService.isPeerReachable(peerID)
            appendCandidate(peerID, connected: connected, reachable: reachable)
        }

        for peer in allPeers {
            let peerID = peer.peerID
            let connected = peer.isConnected || meshService.isPeerConnected(peerID)
            let reachable = peer.isReachable || meshService.isPeerReachable(peerID)
            appendCandidate(peerID, connected: connected, reachable: reachable)
        }

        for peerID in connectedPeers where !candidateIDs.contains(peerID) && !isPeerBlocked(peerID) {
            candidateIDs.append(peerID)
        }

        return candidateIDs.sorted { lhs, rhs in
            let lhsConnected = meshService.isPeerConnected(lhs)
            let rhsConnected = meshService.isPeerConnected(rhs)
            if lhsConnected != rhsConnected {
                return lhsConnected
            }
            let lhsReachable = meshService.isPeerReachable(lhs)
            let rhsReachable = meshService.isPeerReachable(rhs)
            if lhsReachable != rhsReachable {
                return lhsReachable
            }
            return lhs.id < rhs.id
        }
    }
}
