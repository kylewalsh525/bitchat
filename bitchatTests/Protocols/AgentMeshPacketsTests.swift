//
// AgentMeshPacketsTests.swift
// bitchatTests
//

import XCTest
@testable import bitchat

final class AgentMeshPacketsTests: XCTestCase {

    func testAgentInfoV1EncodeDecodeRoundTrip() {
        let info = AgentInfo(role: "general", modelId: "local", qualityScore: 80, modelHash: "abc")
        let data = encodeAgentInfo(info)
        var expected = Data()
        expected.append(AgentMeshConstants.agentInfoVersionV1)
        expected.append(7)
        expected.append("general".data(using: .utf8)!)
        expected.append(5)
        expected.append("local".data(using: .utf8)!)
        expected.append(80)
        expected.append(3)
        expected.append("abc".data(using: .utf8)!)

        XCTAssertEqual(data, expected)

        let decoded = decodeAgentInfo(data)
        XCTAssertEqual(decoded, info)
    }

    func testAgentInfoV2PaymentTermsEncodeDecodeRoundTrip() {
        let terms = AgentPaymentTerms(
            paymentRail: .cashu,
            settlementMode: .offlineAccepted,
            requiresLocking: .p2pk,
            unit: "sat",
            priceModel: .perRequest,
            pricePerRequest: 42,
            acceptedMints: ["https://mint.a", "https://mint.b"],
            requestTTLSeconds: 90
        )
        let info = AgentInfo(role: "general", modelId: "local", qualityScore: 80, modelHash: "abc", paymentTerms: terms)

        let data = encodeAgentInfo(info)
        XCTAssertEqual(data.first, AgentMeshConstants.agentInfoVersionV2)

        let decoded = decodeAgentInfo(data)
        XCTAssertEqual(decoded?.role, "general")
        XCTAssertEqual(decoded?.modelId, "local")
        XCTAssertEqual(decoded?.qualityScore, 80)
        XCTAssertEqual(decoded?.modelHash, "abc")
        XCTAssertEqual(decoded?.paymentTerms?.paymentRail, .cashu)
        XCTAssertEqual(decoded?.paymentTerms?.settlementMode, .offlineAccepted)
        XCTAssertEqual(decoded?.paymentTerms?.requiresLocking, .p2pk)
        XCTAssertEqual(decoded?.paymentTerms?.priceModel, .perRequest)
        XCTAssertEqual(decoded?.paymentTerms?.unit, "sat")
        XCTAssertEqual(decoded?.paymentTerms?.pricePerRequest, 42)
        XCTAssertEqual(decoded?.paymentTerms?.acceptedMints, ["https://mint.a", "https://mint.b"])
        XCTAssertEqual(decoded?.paymentTerms?.requestTTLSeconds, 90)
    }

    func testAgentInfoV2PerTokenTermsEncodeDecodeRoundTrip() {
        let terms = AgentPaymentTerms(
            paymentRail: .cashu,
            settlementMode: .onlineRequired,
            unit: "sat",
            priceModel: .perToken,
            pricePerRequest: 0,
            pricePerInputToken: 1,
            pricePerOutputToken: 2,
            minDeposit: 16,
            granularityTokens: 32,
            acceptedMints: ["https://mint.a"],
            requestTTLSeconds: 120
        )
        let info = AgentInfo(role: "writer", modelId: "local", qualityScore: 71, modelHash: "hash", paymentTerms: terms)
        let data = encodeAgentInfo(info)

        XCTAssertEqual(data.first, AgentMeshConstants.agentInfoVersionV2)

        let decoded = decodeAgentInfo(data)
        XCTAssertEqual(decoded?.paymentTerms?.effectivePriceModel, .perToken)
        XCTAssertEqual(decoded?.paymentTerms?.pricePerInputToken, 1)
        XCTAssertEqual(decoded?.paymentTerms?.pricePerOutputToken, 2)
        XCTAssertEqual(decoded?.paymentTerms?.minDeposit, 16)
        XCTAssertEqual(decoded?.paymentTerms?.granularityTokens, 32)
    }

    func testAgentInfoV2X402PaymentTermsEncodeDecodeRoundTrip() {
        let terms = AgentPaymentTerms(
            paymentRail: .x402,
            settlementMode: .onlineRequired,
            requiresLocking: AgentPaymentLockingMode.none,
            unit: "usdc",
            priceModel: .perRequest,
            pricePerRequest: 125,
            acceptedMints: [],
            requestTTLSeconds: 75,
            x402ChainID: 8453,
            x402TokenAddress: "0xA0b86991c6218b36c1d19d4a2e9eb0ce3606eb48",
            x402PayTo: "0xfeed00000000000000000000000000000000beef",
            x402GatewayURL: "https://gateway.example",
            x402FacilitatorID: "thirdweb",
            x402Scheme: .exact
        )
        let info = AgentInfo(role: "general", modelId: "local", qualityScore: 80, modelHash: "abc", paymentTerms: terms)
        let data = encodeAgentInfo(info)

        XCTAssertEqual(data.first, AgentMeshConstants.agentInfoVersionV2)

        let decoded = decodeAgentInfo(data)
        XCTAssertEqual(decoded?.paymentTerms?.paymentRail, .x402)
        XCTAssertEqual(decoded?.paymentTerms?.settlementMode, .onlineRequired)
        XCTAssertEqual(decoded?.paymentTerms?.requiresLocking, AgentPaymentLockingMode.none)
        XCTAssertEqual(decoded?.paymentTerms?.unit, "usdc")
        XCTAssertEqual(decoded?.paymentTerms?.pricePerRequest, 125)
        XCTAssertEqual(decoded?.paymentTerms?.acceptedMints, [])
        XCTAssertEqual(decoded?.paymentTerms?.x402ChainID, 8453)
        XCTAssertEqual(decoded?.paymentTerms?.x402TokenAddress, "0xA0b86991c6218b36c1d19d4a2e9eb0ce3606eb48")
        XCTAssertEqual(decoded?.paymentTerms?.x402PayTo, "0xfeed00000000000000000000000000000000beef")
        XCTAssertEqual(decoded?.paymentTerms?.x402GatewayURL, "https://gateway.example")
        XCTAssertEqual(decoded?.paymentTerms?.x402FacilitatorID, "thirdweb")
        XCTAssertEqual(decoded?.paymentTerms?.x402Scheme, .exact)
    }

    func testAgentInfoV2FallsBackToV1WhenExtensionsOverflowTLVLimit() {
        let oversizedMints = (0..<20).map { i in "https://mint\(i)." + String(repeating: "x", count: 40) }
        let terms = AgentPaymentTerms(
            paymentRail: .cashu,
            settlementMode: .onlineRequired,
            unit: "sat",
            priceModel: .perRequest,
            pricePerRequest: 123,
            acceptedMints: oversizedMints,
            requestTTLSeconds: 300
        )
        let info = AgentInfo(role: "general", modelId: "local", qualityScore: 80, modelHash: "abc", paymentTerms: terms)

        let data = encodeAgentInfo(info)
        XCTAssertEqual(data.first, AgentMeshConstants.agentInfoVersionV1)

        let decoded = decodeAgentInfo(data)
        XCTAssertEqual(decoded?.paymentTerms, nil)
    }

    func testAgentInfoTruncation() {
        let longRole = String(repeating: "r", count: 300)
        let longModel = String(repeating: "m", count: 300)
        let longHash = String(repeating: "h", count: 300)
        let info = AgentInfo(role: longRole, modelId: longModel, qualityScore: 255, modelHash: longHash)

        let data = encodeAgentInfo(info)
        XCTAssertEqual(data.first, AgentMeshConstants.agentInfoVersionV1)

        let decoded = decodeAgentInfo(data)
        XCTAssertEqual(decoded?.role.count, AgentMeshConstants.maxTLVStringBytes)
        XCTAssertEqual(decoded?.modelId.count, AgentMeshConstants.maxTLVStringBytes)
        XCTAssertEqual(decoded?.modelHash?.count, AgentMeshConstants.maxTLVStringBytes)
        XCTAssertEqual(decoded?.qualityScore, 100)
    }

    func testAgentRequestEncodeDecodeTruncation() {
        let longPrompt = String(repeating: "p", count: 300)
        let request = AgentRequestPacket(
            requestID: "req-1",
            role: "general",
            prompt: longPrompt,
            sessionID: "sess-1",
            attachmentCount: nil,
            senderAlias: "anon-1234",
            createdAtMs: 123456789,
            ttlMs: 30000
        )
        guard let data = request.encode() else {
            XCTFail("Failed to encode agent request")
            return
        }

        let decoded = AgentRequestPacket.decode(from: data)
        XCTAssertEqual(decoded?.requestID, "req-1")
        XCTAssertEqual(decoded?.role, "general")
        XCTAssertEqual(decoded?.prompt.count, AgentMeshConstants.maxAgentPromptBytes)
        XCTAssertEqual(decoded?.sessionID, "sess-1")
        XCTAssertEqual(decoded?.senderAlias, "anon-1234")
        XCTAssertEqual(decoded?.createdAtMs, 123456789)
        XCTAssertEqual(decoded?.ttlMs, 30000)
    }

    func testAgentRequestEncodeDecodeWithQuoteSelection() {
        let request = AgentRequestPacket(
            requestID: "req-quoted",
            role: "general",
            prompt: "hello",
            sessionID: "sess-quoted",
            attachmentCount: 1,
            senderAlias: "anon-q",
            createdAtMs: 777,
            ttlMs: 10_000,
            quoteID: "quote-1",
            quoteOptionID: "quote-1-opt-a"
        )
        guard let data = request.encode() else {
            XCTFail("Failed to encode quoted request")
            return
        }

        let decoded = AgentRequestPacket.decode(from: data)
        XCTAssertEqual(decoded?.requestID, "req-quoted")
        XCTAssertEqual(decoded?.quoteID, "quote-1")
        XCTAssertEqual(decoded?.quoteOptionID, "quote-1-opt-a")
    }

    func testAgentResponseEncodeDecodeTruncation() {
        let longContent = String(repeating: "c", count: 300)
        let response = AgentResponsePacket(
            requestID: "req-1",
            content: longContent,
            isError: true,
            sessionID: "sess-1",
            chunkIndex: 1,
            chunkTotal: 2
        )
        guard let data = response.encode() else {
            XCTFail("Failed to encode agent response")
            return
        }

        let decoded = AgentResponsePacket.decode(from: data)
        XCTAssertEqual(decoded?.requestID, "req-1")
        XCTAssertEqual(decoded?.content.count, AgentMeshConstants.maxAgentResponseBytes)
        XCTAssertEqual(decoded?.isError, true)
        XCTAssertEqual(decoded?.sessionID, "sess-1")
        XCTAssertEqual(decoded?.chunkIndex, 1)
        XCTAssertEqual(decoded?.chunkTotal, 2)
    }

    func testAgentResponsePaymentFlagsEncodeDecode() {
        let response = AgentResponsePacket(
            requestID: "req-1",
            content: "",
            isError: false,
            sessionID: "sess-1",
            chunkIndex: nil,
            chunkTotal: nil,
            paymentRequired: true,
            paymentRequest: "creq:abc",
            paymentError: "expired"
        )
        guard let data = response.encode() else {
            XCTFail("Failed to encode payment response")
            return
        }

        let decoded = AgentResponsePacket.decode(from: data)
        XCTAssertEqual(decoded?.paymentRequired, true)
        XCTAssertEqual(decoded?.paymentRequest, "creq:abc")
        XCTAssertEqual(decoded?.paymentError, "expired")
        XCTAssertEqual(decoded?.sessionID, "sess-1")
    }

    func testAgentChunkerRoundTrip() {
        let text = String(repeating: "👍", count: 120)
        let chunks = AgentMeshChunker.chunk(text: text, maxBytes: 12)
        XCTAssertFalse(chunks.isEmpty)
        XCTAssertTrue(chunks.allSatisfy { $0.utf8.count <= 12 })
        XCTAssertEqual(chunks.joined(), text)
    }

    func testAgentResponseAssembler() {
        var assembler = AgentResponseAssembler()
        let first = assembler.append(
            requestID: "req-1",
            sessionID: "sess-1",
            chunkIndex: 1,
            chunkTotal: 2,
            content: "Hello ",
            isError: false
        )
        XCTAssertNil(first)

        let second = assembler.append(
            requestID: "req-1",
            sessionID: "sess-1",
            chunkIndex: 2,
            chunkTotal: 2,
            content: "world",
            isError: false
        )
        XCTAssertEqual(second?.content, "Hello world")
        XCTAssertEqual(second?.isError, false)
    }

    func testAgentResponseChunkEncodeDecode() {
        let longContent = String(repeating: "c", count: 300)
        let packet = AgentResponseChunkPacket(
            requestID: "req-1",
            index: 2,
            isFinal: true,
            content: longContent,
            isError: true,
            sessionID: "sess-1"
        )
        guard let data = packet.encode() else {
            XCTFail("Failed to encode agent response chunk")
            return
        }

        let decoded = AgentResponseChunkPacket.decode(from: data)
        XCTAssertEqual(decoded?.requestID, "req-1")
        XCTAssertEqual(decoded?.index, 2)
        XCTAssertEqual(decoded?.isFinal, true)
        XCTAssertEqual(decoded?.isError, true)
        XCTAssertEqual(decoded?.sessionID, "sess-1")
        XCTAssertEqual(decoded?.content.count, AgentMeshConstants.maxAgentResponseBytes)
    }

    func testAgentQuoteRequestPacketRoundTrip() {
        let packet = AgentQuoteRequestPacket(
            quoteID: "quote-abc",
            role: "general",
            prompt: "summarize this",
            estimatedInputTokens: 64,
            estimatedOutputTokens: 128,
            sentAt: 1_730_000_001_000,
            maxOptions: 3
        )
        guard let data = packet.encode() else {
            XCTFail("Failed to encode AgentQuoteRequestPacket")
            return
        }

        let decoded = AgentQuoteRequestPacket.decode(from: data)
        XCTAssertEqual(decoded?.quoteID, "quote-abc")
        XCTAssertEqual(decoded?.role, "general")
        XCTAssertEqual(decoded?.prompt, "summarize this")
        XCTAssertEqual(decoded?.estimatedInputTokens, 64)
        XCTAssertEqual(decoded?.estimatedOutputTokens, 128)
        XCTAssertEqual(decoded?.sentAt, 1_730_000_001_000)
        XCTAssertEqual(decoded?.maxOptions, 3)
    }

    func testAgentQuoteResponsePacketRoundTrip() {
        let options = [
            AgentQuoteOption(
                optionID: "quote-abc-immediate",
                label: "immediate",
                waitSeconds: 0,
                discountBps: 0,
                estimatedPrice: 100,
                unit: "sat",
                settlementMode: .offlineAccepted,
                requiresLocking: .p2pk,
                acceptedMints: ["https://mint.example"],
                requestTTLSeconds: 60,
                qualityScore: 90,
                modelId: "llama",
                modelHash: "ollama:sha256:abcd"
            )
        ]
        let packet = AgentQuoteResponsePacket(
            quoteID: "quote-abc",
            role: "general",
            options: options,
            expiresAt: 1_730_000_002_000,
            error: nil
        )
        guard let data = packet.encode() else {
            XCTFail("Failed to encode AgentQuoteResponsePacket")
            return
        }

        let decoded = AgentQuoteResponsePacket.decode(from: data)
        XCTAssertEqual(decoded?.quoteID, "quote-abc")
        XCTAssertEqual(decoded?.role, "general")
        XCTAssertEqual(decoded?.options, options)
        XCTAssertEqual(decoded?.expiresAt, 1_730_000_002_000)
        XCTAssertNil(decoded?.error)
    }

    func testAgentQuoteResponsePacketRoundTripX402Option() {
        let options = [
            AgentQuoteOption(
                optionID: "quote-x402-immediate",
                label: "immediate",
                waitSeconds: 0,
                discountBps: 0,
                estimatedPrice: 250,
                paymentRail: .x402,
                unit: "usdc",
                settlementMode: .onlineRequired,
                requiresLocking: AgentPaymentLockingMode.none,
                acceptedMints: [],
                requestTTLSeconds: 120,
                chainID: 8453,
                tokenAddress: "0xA0b86991c6218b36c1d19d4a2e9eb0ce3606eb48",
                qualityScore: 88,
                modelId: "gpt-oss",
                modelHash: "sha256:abcd"
            )
        ]
        let packet = AgentQuoteResponsePacket(
            quoteID: "quote-x402",
            role: "general",
            options: options,
            expiresAt: 1_730_000_002_000,
            error: nil
        )
        guard let data = packet.encode() else {
            XCTFail("Failed to encode AgentQuoteResponsePacket")
            return
        }

        let decoded = AgentQuoteResponsePacket.decode(from: data)
        XCTAssertEqual(decoded?.options.first?.paymentRail, .x402)
        XCTAssertEqual(decoded?.options.first?.chainID, 8453)
        XCTAssertEqual(decoded?.options.first?.tokenAddress, "0xA0b86991c6218b36c1d19d4a2e9eb0ce3606eb48")
        XCTAssertEqual(decoded?.options.first?.acceptedMints, [])
    }

    func testAgentQuoteOptionDecodeDefaultsRailToCashuWhenFieldMissing() throws {
        let json = """
        {
          "optionID":"legacy-opt",
          "label":"legacy",
          "waitSeconds":0,
          "discountBps":0,
          "estimatedPrice":100,
          "unit":"sat",
          "settlementMode":"online_required",
          "acceptedMints":["https://mint.example"],
          "requestTTLSeconds":60,
          "qualityScore":90,
          "modelId":"legacy-model",
          "modelHash":"sha256:abcd"
        }
        """
        let option = try JSONDecoder().decode(AgentQuoteOption.self, from: Data(json.utf8))
        XCTAssertEqual(option.paymentRail, .cashu)
        XCTAssertEqual(option.acceptedMints, ["https://mint.example"])
    }

    func testAgentPaymentPayloadPacketRoundTrip() {
        let packet = AgentPaymentPayloadPacket(
            requestID: "req-1",
            sessionID: "sess-1",
            rail: "cashu",
            payload: "{\"proofs\":[]}",
            sentAt: 1_730_000_000_123,
            clientNonce: "nonce-1"
        )
        guard let data = packet.encode() else {
            XCTFail("Failed to encode AgentPaymentPayloadPacket")
            return
        }

        let decoded = AgentPaymentPayloadPacket.decode(from: data)
        XCTAssertEqual(decoded?.requestID, "req-1")
        XCTAssertEqual(decoded?.sessionID, "sess-1")
        XCTAssertEqual(decoded?.rail, "cashu")
        XCTAssertEqual(decoded?.payload, "{\"proofs\":[]}")
        XCTAssertEqual(decoded?.sentAt, 1_730_000_000_123)
        XCTAssertEqual(decoded?.clientNonce, "nonce-1")
    }

    func testAgentPaymentReceiptPacketRoundTrip() {
        let packet = AgentPaymentReceiptPacket(
            requestID: "req-1",
            sessionID: "sess-1",
            paymentID: "pay-1",
            status: .acceptedOffline,
            details: "accepted offline",
            nullifiers: ["n1", "n2"],
            notaryReceipts: ["r1"],
            fairUnlockKey: "aunlock1:test"
        )
        guard let data = packet.encode() else {
            XCTFail("Failed to encode AgentPaymentReceiptPacket")
            return
        }

        let decoded = AgentPaymentReceiptPacket.decode(from: data)
        XCTAssertEqual(decoded?.requestID, "req-1")
        XCTAssertEqual(decoded?.sessionID, "sess-1")
        XCTAssertEqual(decoded?.paymentID, "pay-1")
        XCTAssertEqual(decoded?.status, .acceptedOffline)
        XCTAssertEqual(decoded?.details, "accepted offline")
        XCTAssertEqual(decoded?.nullifiers, ["n1", "n2"])
        XCTAssertEqual(decoded?.notaryReceipts, ["r1"])
        XCTAssertEqual(decoded?.fairUnlockKey, "aunlock1:test")
    }

    func testMintProxyRequestPacketRoundTrip() {
        let packet = MintProxyRequestPacket(
            proxyID: "proxy-1",
            mintURL: "https://mint.example",
            method: .swap,
            body: "{\"inputs\":[]}",
            sentAt: 1_730_000_000_555
        )
        guard let data = packet.encode() else {
            XCTFail("Failed to encode MintProxyRequestPacket")
            return
        }

        let decoded = MintProxyRequestPacket.decode(from: data)
        XCTAssertEqual(decoded?.proxyID, "proxy-1")
        XCTAssertEqual(decoded?.mintURL, "https://mint.example")
        XCTAssertEqual(decoded?.method, .swap)
        XCTAssertEqual(decoded?.body, "{\"inputs\":[]}")
        XCTAssertEqual(decoded?.sentAt, 1_730_000_000_555)
    }

    func testMintProxyRequestPacketRelockRoundTrip() {
        let packet = MintProxyRequestPacket(
            proxyID: "proxy-relock-1",
            mintURL: "https://mint.example",
            method: .relock,
            body: "{\"requestID\":\"req-1\",\"paymentID\":\"pay-1\"}",
            sentAt: 1_730_000_000_777
        )
        guard let data = packet.encode() else {
            XCTFail("Failed to encode relock MintProxyRequestPacket")
            return
        }

        let decoded = MintProxyRequestPacket.decode(from: data)
        XCTAssertEqual(decoded?.proxyID, "proxy-relock-1")
        XCTAssertEqual(decoded?.mintURL, "https://mint.example")
        XCTAssertEqual(decoded?.method, .relock)
        XCTAssertEqual(decoded?.body, "{\"requestID\":\"req-1\",\"paymentID\":\"pay-1\"}")
        XCTAssertEqual(decoded?.sentAt, 1_730_000_000_777)
    }

    func testMintProxyResponsePacketRoundTrip() {
        let packet = MintProxyResponsePacket(
            proxyID: "proxy-1",
            ok: false,
            body: nil,
            error: "mint unreachable"
        )
        guard let data = packet.encode() else {
            XCTFail("Failed to encode MintProxyResponsePacket")
            return
        }

        let decoded = MintProxyResponsePacket.decode(from: data)
        XCTAssertEqual(decoded?.proxyID, "proxy-1")
        XCTAssertEqual(decoded?.ok, false)
        XCTAssertEqual(decoded?.body, nil)
        XCTAssertEqual(decoded?.error, "mint unreachable")
    }
}
