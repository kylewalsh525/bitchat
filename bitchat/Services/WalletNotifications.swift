import Foundation

extension Notification.Name {
    static let cashuWalletDidUpdate = Notification.Name("bitchat.CashuWalletDidUpdate")
    static let thirdwebWalletDidUpdate = Notification.Name("bitchat.ThirdwebWalletDidUpdate")
}

enum WalletNotificationKeys {
    static let source = "source"
    static let requestID = "requestID"
    static let rail = "rail"
    static let reason = "reason"
}
