import Foundation
import Combine
#if canImport(WebKit)
import WebKit
#endif

enum ThirdwebGuestWalletError: LocalizedError {
    case unsupportedPlatform
    case missingClientID
    case pageLoadFailed
    case bridgeTimeout
    case malformedResponse
    case unavailable(String)

    var errorDescription: String? {
        switch self {
        case .unsupportedPlatform:
            return "thirdweb wallet bridge is not supported on this platform"
        case .missingClientID:
            return "thirdweb client id is missing"
        case .pageLoadFailed:
            return "failed to initialize thirdweb web wallet runtime"
        case .bridgeTimeout:
            return "thirdweb wallet bridge timed out"
        case .malformedResponse:
            return "thirdweb wallet bridge returned malformed response"
        case .unavailable(let reason):
            return reason
        }
    }
}

@MainActor
final class ThirdwebGuestWalletBridge: NSObject, ObservableObject, X402GuestWalletPaying {
    static let clientIDKey = "bitchat.thirdweb.client.id"
    static let walletAddressKey = "bitchat.thirdweb.wallet.address"
    static let linkedKey = "bitchat.thirdweb.wallet.linked"

    private let defaults: UserDefaults

    @Published private(set) var walletAddress: String?
    @Published private(set) var isLinked: Bool

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        self.walletAddress = defaults.string(forKey: Self.walletAddressKey)
        self.isLinked = defaults.bool(forKey: Self.linkedKey)
        super.init()
    }

    func configuredClientID() -> String? {
        let value = defaults.string(forKey: Self.clientIDKey)?.trimmingCharacters(in: .whitespacesAndNewlines)
        return (value?.isEmpty == false) ? value : nil
    }

    func setConfiguredClientID(_ clientID: String?) {
        let trimmed = clientID?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if trimmed.isEmpty {
            defaults.removeObject(forKey: Self.clientIDKey)
        } else {
            defaults.set(trimmed, forKey: Self.clientIDKey)
        }
    }

    func ensureGuestWallet() async throws -> String {
        let clientID = try requireClientID()
        let address = try await callBridge(
            method: "ensureGuestWallet",
            args: ["clientID": clientID]
        )
        walletAddress = address
        defaults.set(address, forKey: Self.walletAddressKey)
        return address
    }

    func payX402(
        gatewayURL: String,
        paymentID: String,
        requestID: String,
        amount: UInt64,
        chainID: UInt64,
        tokenAddress: String,
        payTo: String
    ) async throws -> X402WalletPaymentResult {
        let clientID = try requireClientID()
        let response = try await callBridge(
            method: "payX402",
            args: [
                "clientID": clientID,
                "gatewayURL": gatewayURL,
                "paymentID": paymentID,
                "requestID": requestID,
                "amount": String(amount),
                "chainID": String(chainID),
                "tokenAddress": tokenAddress,
                "payTo": payTo
            ],
            timeoutSeconds: 35
        )
        guard let data = response.data(using: .utf8),
              let payload = try? JSONDecoder().decode(BridgePaymentResult.self, from: data),
              !payload.paymentData.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              !payload.payerAddress.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw ThirdwebGuestWalletError.malformedResponse
        }

        walletAddress = payload.payerAddress
        defaults.set(payload.payerAddress, forKey: Self.walletAddressKey)
        return X402WalletPaymentResult(paymentData: payload.paymentData, payerAddress: payload.payerAddress)
    }

    func linkWallet() async throws {
        let clientID = try requireClientID()
        _ = try await callBridge(
            method: "linkPasskey",
            args: ["clientID": clientID],
            timeoutSeconds: 35
        )
        isLinked = true
        defaults.set(true, forKey: Self.linkedKey)
    }

    func exportPrivateKey() async throws -> String {
        throw ThirdwebGuestWalletError.unavailable(
            "Programmatic private key export is not supported by thirdweb. Use Manage Wallet -> Export Private Key in thirdweb Connect UI."
        )
    }

    func resetWallet() async {
        _ = try? await callBridge(method: "resetWallet", args: [:], timeoutSeconds: 10)
        walletAddress = nil
        isLinked = false
        defaults.removeObject(forKey: Self.walletAddressKey)
        defaults.removeObject(forKey: Self.linkedKey)
    }

    private func requireClientID() throws -> String {
        guard let clientID = configuredClientID(), !clientID.isEmpty else {
            throw ThirdwebGuestWalletError.missingClientID
        }
        return clientID
    }

    private struct BridgePaymentResult: Codable {
        let paymentData: String
        let payerAddress: String
    }
}

#if canImport(WebKit)
@MainActor
private final class ThirdwebBridgeRuntime: NSObject, WKScriptMessageHandler, WKNavigationDelegate {
    static let shared = ThirdwebBridgeRuntime()

    private var webView: WKWebView?
    private var loaded = false
    private var loadWaiters: [CheckedContinuation<Void, Error>] = []
    private var continuations: [String: CheckedContinuation<String, Error>] = [:]

    func call(method: String, args: [String: String], timeoutSeconds: TimeInterval) async throws -> String {
        try await ensureLoaded()
        guard let webView else { throw ThirdwebGuestWalletError.pageLoadFailed }

        let id = UUID().uuidString.lowercased()
        let payloadData = try JSONEncoder().encode(args)
        guard let payloadJSON = String(data: payloadData, encoding: .utf8) else {
            throw ThirdwebGuestWalletError.malformedResponse
        }

        return try await withCheckedThrowingContinuation { continuation in
            continuations[id] = continuation

            let escapedMethod = Self.escapeJSString(method)
            let escapedID = Self.escapeJSString(id)
            let script = "window.bitchatThirdwebRPC('\(escapedMethod)','\(escapedID)',\(payloadJSON));"
            webView.evaluateJavaScript(script) { [weak self] _, error in
                guard let self else { return }
                if let error {
                    self.resolve(id: id, result: .failure(error))
                }
            }

            Task { @MainActor [weak self] in
                guard let self else { return }
                try? await Task.sleep(nanoseconds: UInt64(max(1, timeoutSeconds) * 1_000_000_000))
                if self.continuations[id] != nil {
                    self.resolve(id: id, result: .failure(ThirdwebGuestWalletError.bridgeTimeout))
                }
            }
        }
    }

    private func ensureLoaded() async throws {
        if loaded { return }
        if webView == nil {
            let config = WKWebViewConfiguration()
            let controller = WKUserContentController()
            controller.add(self, name: "thirdwebBridge")
            config.userContentController = controller
            let webView = WKWebView(frame: .zero, configuration: config)
            webView.navigationDelegate = self
            self.webView = webView
            webView.loadHTMLString(Self.bridgeHTML, baseURL: URL(string: "https://localhost/"))
        }

        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            loadWaiters.append(continuation)
        }
    }

    func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
        guard message.name == "thirdwebBridge" else { return }
        guard let body = message.body as? [String: Any],
              let id = body["id"] as? String else {
            return
        }
        let ok = (body["ok"] as? Bool) == true
        if ok {
            let value = body["value"] as? String ?? ""
            resolve(id: id, result: .success(value))
        } else {
            let error = body["error"] as? String ?? "thirdweb bridge error"
            resolve(id: id, result: .failure(ThirdwebGuestWalletError.unavailable(error)))
        }
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        loaded = true
        let waiters = loadWaiters
        loadWaiters.removeAll(keepingCapacity: false)
        for waiter in waiters {
            waiter.resume()
        }
    }

    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        failLoad(error: error)
    }

    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        failLoad(error: error)
    }

    private func failLoad(error: Error) {
        let waiters = loadWaiters
        loadWaiters.removeAll(keepingCapacity: false)
        for waiter in waiters {
            waiter.resume(throwing: error)
        }
    }

    private func resolve(id: String, result: Result<String, Error>) {
        guard let continuation = continuations.removeValue(forKey: id) else { return }
        switch result {
        case .success(let value):
            continuation.resume(returning: value)
        case .failure(let error):
            continuation.resume(throwing: error)
        }
    }

    private static func escapeJSString(_ value: String) -> String {
        value
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "'", with: "\\'")
            .replacingOccurrences(of: "\n", with: "\\n")
            .replacingOccurrences(of: "\r", with: "")
    }

    private static let bridgeHTML = """
<!doctype html>
<html>
<head>
  <meta charset="utf-8" />
  <meta name="viewport" content="width=device-width, initial-scale=1" />
  <title>thirdweb bridge</title>
</head>
<body>
<script type="module">
import { createThirdwebClient } from "https://esm.sh/thirdweb@5";
import { inAppWallet, linkProfile } from "https://esm.sh/thirdweb@5/wallets";
import { wrapFetchWithPayment } from "https://esm.sh/thirdweb@5/x402";

const state = {
  clientID: null,
  client: null,
  wallet: null,
  account: null,
};

function send(id, ok, value, error) {
  window.webkit?.messageHandlers?.thirdwebBridge?.postMessage({ id, ok, value, error });
}

async function ensureWallet(clientID) {
  if (!clientID || typeof clientID !== "string") {
    throw new Error("missing thirdweb client id");
  }
  if (state.clientID !== clientID || !state.client || !state.wallet) {
    state.clientID = clientID;
    state.client = createThirdwebClient({ clientId: clientID });
    state.wallet = inAppWallet({
      auth: { options: ["guest", "passkey", "email", "google", "apple"] },
    });
    state.account = null;
  }
  if (!state.account) {
    state.account = await state.wallet.connect({
      client: state.client,
      strategy: "guest",
    });
  }
  return state.account.address;
}

window.bitchatThirdwebRPC = async (method, id, args) => {
  try {
    if (method === "ensureGuestWallet") {
      const address = await ensureWallet(args.clientID);
      send(id, true, address, null);
      return;
    }

    if (method === "payX402") {
      const address = await ensureWallet(args.clientID);
      const fetchWithPayment = wrapFetchWithPayment(
        fetch,
        state.client,
        state.wallet,
        BigInt(args.amount || "0"),
      );
      const target = String(args.gatewayURL || "").replace(/\\/+$/, "") + "/x402/prepare";
      const response = await fetchWithPayment(target, {
        method: "POST",
        headers: { "Content-Type": "application/json" },
        body: JSON.stringify({
          paymentID: args.paymentID,
          requestID: args.requestID,
          amount: args.amount,
          chainID: args.chainID,
          tokenAddress: args.tokenAddress,
          payTo: args.payTo,
        }),
      });

      if (!response.ok) {
        const body = await response.text();
        throw new Error("x402 prepare failed: " + response.status + " " + body);
      }
      const payload = await response.json();
      if (!payload || !payload.paymentData) {
        throw new Error("x402 prepare response missing paymentData");
      }

      send(id, true, JSON.stringify({
        paymentData: payload.paymentData,
        payerAddress: payload.payerAddress || address
      }), null);
      return;
    }

    if (method === "linkPasskey") {
      await ensureWallet(args.clientID);
      await linkProfile(state.wallet, { strategy: "passkey" });
      send(id, true, "linked", null);
      return;
    }

    if (method === "resetWallet") {
      if (state.wallet) {
        try { await state.wallet.disconnect(); } catch {}
      }
      state.clientID = null;
      state.client = null;
      state.wallet = null;
      state.account = null;
      send(id, true, "ok", null);
      return;
    }

    send(id, false, null, "unknown method");
  } catch (error) {
    const message = error?.message || String(error);
    send(id, false, null, message);
  }
};
</script>
</body>
</html>
"""
}
#endif

@MainActor
extension ThirdwebGuestWalletBridge {
    fileprivate func callBridge(method: String, args: [String: String], timeoutSeconds: TimeInterval = 20) async throws -> String {
        #if canImport(WebKit)
        return try await ThirdwebBridgeRuntime.shared.call(method: method, args: args, timeoutSeconds: timeoutSeconds)
        #else
        throw ThirdwebGuestWalletError.unsupportedPlatform
        #endif
    }
}
