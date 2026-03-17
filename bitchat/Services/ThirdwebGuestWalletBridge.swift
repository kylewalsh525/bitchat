import Foundation
import Combine
#if canImport(WebKit)
import WebKit
#endif

@MainActor
protocol ThirdwebBridgeRuntimeCalling {
    func call(method: String, args: [String: String], timeoutSeconds: TimeInterval) async throws -> String
    func prewarm(timeoutSeconds: TimeInterval) async throws
}

enum ThirdwebGuestWalletError: LocalizedError {
    case unsupportedPlatform
    case missingClientID
    case pageLoadFailed
    case runtimeNotReady
    case bridgeTimeout
    case malformedResponse
    case unavailable(String)

    var errorDescription: String? {
        switch self {
        case .unsupportedPlatform:
            return "thirdweb wallet bridge is not supported on this platform"
        case .missingClientID:
            #if DEBUG
            return "x402 isn't available in this build. Add THIRDWEB_CLIENT_ID in Configs/Local.xcconfig and rebuild."
            #else
            return "x402 isn't available in this build"
            #endif
        case .pageLoadFailed:
            return "failed to initialize thirdweb web wallet runtime"
        case .runtimeNotReady:
            return "thirdweb runtime is still loading, try again"
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
    static let bundleClientIDInfoKey = "ThirdwebClientID"

    private let defaults: UserDefaults
    private let runtime: ThirdwebBridgeRuntimeCalling

    @Published private(set) var walletAddress: String?
    @Published private(set) var isLinked: Bool

    var isBridgeAvailable: Bool {
#if canImport(WebKit)
        return true
#else
        return false
#endif
    }

    private func emitWalletUpdate(reason: String, requestID: String? = nil) {
        var payload: [String: String] = [
            WalletNotificationKeys.source: "ThirdwebGuestWalletBridge",
            WalletNotificationKeys.rail: AgentPaymentRail.x402.rawValue,
            WalletNotificationKeys.reason: reason
        ]
        if let requestID {
            payload[WalletNotificationKeys.requestID] = requestID
        }
        NotificationCenter.default.post(
            name: .thirdwebWalletDidUpdate,
            object: self,
            userInfo: payload
        )
    }

    init(defaults: UserDefaults = .standard, runtime: ThirdwebBridgeRuntimeCalling? = nil) {
        self.defaults = defaults
        self.walletAddress = defaults.string(forKey: Self.walletAddressKey)
        self.isLinked = defaults.bool(forKey: Self.linkedKey)
        #if canImport(WebKit)
        self.runtime = runtime ?? ThirdwebBridgeRuntime.shared
        #else
        self.runtime = runtime ?? UnsupportedThirdwebBridgeRuntime()
        #endif
        super.init()
    }

    private func bundleClientID() -> String? {
        guard let value = Bundle.main.object(forInfoDictionaryKey: Self.bundleClientIDInfoKey) as? String else {
            return nil
        }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        // If the build setting wasn't substituted, Xcode may leave a placeholder like `$(THIRDWEB_CLIENT_ID)`.
        guard !trimmed.contains("$(") else { return nil }
        return trimmed
    }

    private func environmentClientID() -> String? {
        let value = ProcessInfo.processInfo.environment["THIRDWEB_CLIENT_ID"] ?? ""
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        return trimmed
    }

    func configuredClientID() -> String? {
        // Developer override (stored on-device). Users should not need to set this in normal builds.
        if let override = defaults.string(forKey: Self.clientIDKey)?
            .trimmingCharacters(in: .whitespacesAndNewlines),
           !override.isEmpty {
            return override
        }
        // Dev convenience (Xcode scheme env var / local launch): allow runtime env override.
        if let env = environmentClientID() {
            return env
        }
        return bundleClientID()
    }

    func setConfiguredClientID(_ clientID: String?) {
        let trimmed = clientID?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if trimmed.isEmpty {
            defaults.removeObject(forKey: Self.clientIDKey)
        } else {
            defaults.set(trimmed, forKey: Self.clientIDKey)
        }
        emitWalletUpdate(reason: "client-id-updated")
    }

    func prewarm(timeoutSeconds: TimeInterval = 20) async {
        guard isBridgeAvailable else { return }
        _ = try? await runtime.prewarm(timeoutSeconds: timeoutSeconds)
    }

    func ensureGuestWallet() async throws -> String {
        let clientID = try requireClientID()
        let address = try await callBridge(
            method: "ensureGuestWallet",
            args: ["clientID": clientID]
        )
        walletAddress = address
        defaults.set(address, forKey: Self.walletAddressKey)
        emitWalletUpdate(reason: "ensureGuestWallet-success")
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
        emitWalletUpdate(reason: "payX402-success", requestID: paymentID)
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
        emitWalletUpdate(reason: "linkWallet-success")
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
        emitWalletUpdate(reason: "resetWallet-success")
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
private final class ThirdwebBridgeRuntime: NSObject, WKScriptMessageHandler, WKNavigationDelegate, ThirdwebBridgeRuntimeCalling {
    static let shared = ThirdwebBridgeRuntime()

    private var webView: WKWebView?
    private var loaded = false
    private var runtimeReady = false
    private var loadWaiters: [CheckedContinuation<Void, Error>] = []
    private var continuations: [String: CheckedContinuation<String, Error>] = [:]

    func call(method: String, args: [String: String], timeoutSeconds: TimeInterval) async throws -> String {
        try await ensureLoaded(timeoutSeconds: 20)
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
                    self.resolve(id: id, result: .failure(self.mapBridgeError(error)))
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

    func prewarm(timeoutSeconds: TimeInterval) async throws {
        try await ensureLoaded(timeoutSeconds: timeoutSeconds)
    }

    private func ensureLoaded(timeoutSeconds: TimeInterval) async throws {
        if loaded && runtimeReady { return }
        if loaded && !runtimeReady {
            try await waitForRuntimeReady(timeoutSeconds: timeoutSeconds)
            return
        }
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
        try await waitForRuntimeReady(timeoutSeconds: timeoutSeconds)
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

    func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
        // WebKit can kill the web content process under memory pressure or crashes.
        // Clear state so the next action recreates the runtime cleanly.
        loaded = false
        runtimeReady = false
        self.webView = nil

        let terminationError = ThirdwebGuestWalletError.unavailable("thirdweb restarted. Try again.")

        let waiters = loadWaiters
        loadWaiters.removeAll(keepingCapacity: false)
        for waiter in waiters {
            waiter.resume(throwing: terminationError)
        }

        let pending = continuations
        continuations.removeAll(keepingCapacity: false)
        for (_, continuation) in pending {
            continuation.resume(throwing: terminationError)
        }
    }

    private func failLoad(error: Error) {
        loaded = false
        runtimeReady = false
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

    private func mapBridgeError(_ error: Error) -> Error {
        let nsError = error as NSError
        let description = nsError.localizedDescription.lowercased()
        if nsError.domain == NSURLErrorDomain {
            switch nsError.code {
            case NSURLErrorNotConnectedToInternet:
                return ThirdwebGuestWalletError.unavailable("No internet connection. x402 needs internet to provision and pay.")
            case NSURLErrorTimedOut:
                return ThirdwebGuestWalletError.unavailable("Network timed out. Try again on a stronger connection.")
            case NSURLErrorCannotFindHost, NSURLErrorCannotConnectToHost, NSURLErrorCannotLoadFromNetwork, NSURLErrorDNSLookupFailed:
                return ThirdwebGuestWalletError.unavailable("thirdweb bridge network failed. Check internet access and firewall/VPN.")
            default:
                break
            }
        }
        if description.contains("javascript") && description.contains("undefined") {
            return ThirdwebGuestWalletError.runtimeNotReady
        }
        if description.contains("module script") ||
            description.contains("importing a module script failed") ||
            description.contains("failed to fetch dynamically imported module") {
            return ThirdwebGuestWalletError.unavailable("thirdweb couldn't load its web libraries. Check third-party CDN access.")
        }
        if description.contains("script") && description.contains("exception") {
            return ThirdwebGuestWalletError.unavailable("thirdweb runtime reported a script error. Check internet, then retry.")
        }
        return error
    }

    private static func escapeJSString(_ value: String) -> String {
        value
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "'", with: "\\'")
            .replacingOccurrences(of: "\n", with: "\\n")
            .replacingOccurrences(of: "\r", with: "")
    }

    private struct RuntimeProbe: Decodable {
        let ready: Bool
        let initError: String
    }

    private func waitForRuntimeReady(timeoutSeconds: TimeInterval) async throws {
        guard let webView else { throw ThirdwebGuestWalletError.pageLoadFailed }
        if runtimeReady { return }

        let deadline = Date().addingTimeInterval(max(1, timeoutSeconds))
        while Date() < deadline {
            let json = try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<String, Error>) in
                webView.evaluateJavaScript(
                    "JSON.stringify({ready: window.bitchatThirdwebReady === true, initError: window.bitchatThirdwebInitError || ''})"
                ) { value, error in
                    if let error {
                        continuation.resume(throwing: error)
                        return
                    }
                    continuation.resume(returning: value as? String ?? "")
                }
            }

            if let data = json.data(using: .utf8),
               let probe = try? JSONDecoder().decode(RuntimeProbe.self, from: data) {
                if probe.ready {
                    runtimeReady = true
                    return
                }
                let initError = probe.initError.trimmingCharacters(in: .whitespacesAndNewlines)
                if !initError.isEmpty {
                    throw ThirdwebGuestWalletError.unavailable(Self.friendlyInitError(initError))
                }
            }

            try await Task.sleep(nanoseconds: 200_000_000)
        }
        throw ThirdwebGuestWalletError.runtimeNotReady
    }

    private static func friendlyInitError(_ raw: String) -> String {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return "thirdweb failed to start." }
        let lowered = trimmed.lowercased()
        if lowered.contains("importing a module script failed") ||
            lowered.contains("failed to fetch dynamically imported module") ||
            lowered.contains("failed to parse") ||
            lowered.contains("failed to load thirdweb modules") ||
            lowered.contains("module script") ||
            lowered.contains("failed to fetch") ||
            lowered.contains("module script failed") ||
            lowered.contains("module specifier") ||
            lowered.contains("load failed") ||
            lowered.contains("not connected") ||
            lowered.contains("network") {
            return "thirdweb couldn't load its web libraries. Check your internet + CDN access (esm.sh / jsdelivr / unpkg), then try again."
        }
        return "thirdweb failed to start: \(trimmed)"
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
window.bitchatThirdwebReady = false;
window.bitchatThirdwebInitError = "";

const state = {
  clientID: null,
  client: null,
  wallet: null,
  account: null,
  x402: null,
};

function send(id, ok, value, error) {
  window.webkit?.messageHandlers?.thirdwebBridge?.postMessage({ id, ok, value, error });
}

(async () => {
  try {
    const importTimeoutMs = 12000;
    const cacheBust = Date.now().toString(36);
    function withTimeout(promise, timeoutMs, label) {
      let timeoutID = null;
      const timeoutPromise = new Promise((_, reject) => {
        timeoutID = setTimeout(() => {
          reject(new Error(`${label} timed out after ${timeoutMs}ms`));
        }, timeoutMs);
      });
      return Promise.race([promise, timeoutPromise]).finally(() => {
        if (timeoutID !== null) {
          clearTimeout(timeoutID);
        }
      });
    }

    function withCacheBust(url) {
      return url.includes("?")
        ? (url + "&bitchatcb=" + cacheBust)
        : (url + "?bitchatcb=" + cacheBust);
    }

    async function importWithFallback(urls) {
      let lastError = null;
      const errors = [];
      for (const url of urls) {
        const attempts = [url, withCacheBust(url)];
        for (const attempt of attempts) {
          try {
            return await withTimeout(import(attempt), importTimeoutMs, `import ${attempt}`);
          } catch (err) {
            lastError = err;
            const message = err?.message || String(err);
            errors.push(attempt + ": " + message);
          }
        }
      }
      const detail = errors.length ? errors.join(" | ") : (lastError?.message || String(lastError));
      throw new Error("failed to load thirdweb modules: " + detail);
    }

    const thirdweb = await importWithFallback([
      "https://unpkg.com/thirdweb@5/dist/esm/exports/thirdweb.js",
      "https://cdn.jsdelivr.net/npm/thirdweb@5/+esm",
      "https://esm.sh/thirdweb@5?target=es2020",
      "https://esm.sh/thirdweb@5?target=es2020&bundle",
    ]);
    const wallets = await importWithFallback([
      "https://unpkg.com/thirdweb@5/dist/esm/exports/wallets/in-app.js",
      "https://cdn.jsdelivr.net/npm/thirdweb@5/wallets/+esm",
      "https://esm.sh/thirdweb@5/wallets?target=es2020",
      "https://esm.sh/thirdweb@5/wallets?target=es2020&bundle",
    ]);

    const { createThirdwebClient } = thirdweb;
    const { inAppWallet } = wallets;

    async function ensureX402() {
      if (!state.x402) {
        state.x402 = await importWithFallback([
          "https://unpkg.com/thirdweb@5/dist/esm/exports/x402.js",
          "https://cdn.jsdelivr.net/npm/thirdweb@5/x402/+esm",
          "https://esm.sh/thirdweb@5/x402?target=es2020",
          "https://esm.sh/thirdweb@5/x402?target=es2020&bundle",
        ]);
      }
      return state.x402;
    }

    async function ensureWallet(clientID) {
      if (!clientID || typeof clientID !== "string") {
        throw new Error("missing thirdweb client id");
      }
      if (state.clientID !== clientID || !state.client || !state.wallet) {
        state.clientID = clientID;
        state.client = createThirdwebClient({ clientId: clientID });
        state.wallet = inAppWallet({
          auth: { options: ["guest"] },
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
          const x402 = await ensureX402();
          const { wrapFetchWithPayment } = x402;
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
          send(id, false, null, "linking is unavailable in the embedded wallet runtime");
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

    window.bitchatThirdwebReady = true;
  } catch (error) {
    const message = error?.message || String(error);
    window.bitchatThirdwebInitError = message;
    window.bitchatThirdwebReady = false;
  }
})();
</script>
</body>
</html>
"""
}
#endif

#if !canImport(WebKit)
@MainActor
private final class UnsupportedThirdwebBridgeRuntime: ThirdwebBridgeRuntimeCalling {
    func call(method: String, args: [String : String], timeoutSeconds: TimeInterval) async throws -> String {
        throw ThirdwebGuestWalletError.unsupportedPlatform
    }

    func prewarm(timeoutSeconds: TimeInterval) async throws {
        throw ThirdwebGuestWalletError.unsupportedPlatform
    }
}
#endif

@MainActor
extension ThirdwebGuestWalletBridge {
    fileprivate func callBridge(method: String, args: [String: String], timeoutSeconds: TimeInterval = 20) async throws -> String {
        try await runtime.call(method: method, args: args, timeoutSeconds: timeoutSeconds)
    }
}
