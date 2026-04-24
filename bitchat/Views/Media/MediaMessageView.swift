//
//  MediaMessageView.swift
//  bitchat
//
//  Created by Islam on 30/03/2026.
//

import SwiftUI
import BitFoundation
import BitLogger
#if os(macOS)
import AppKit
#endif

struct MediaMessageView: View {
    @Environment(\.colorScheme) private var colorScheme

    @EnvironmentObject var viewModel: ChatViewModel
    let message: BitchatMessage
    let media: BitchatMessage.Media

    @Binding var imagePreviewURL: URL?
    @Binding var exportMediaURL: URL?

    var body: some View {
        let state = mediaSendState(for: message)
        let mediaURL = media.url
        let isOutgoing = mediaURL.path.contains("/outgoing/")
        let isFromMe = isOutgoing || viewModel.isSelfMessage(message)
        let shouldBlurImage = !isFromMe && !message.isPrivate
        let cancelAction: (() -> Void)? = state.canCancel ? { viewModel.cancelMediaSend(messageID: message.id) } : nil

        VStack(alignment: .leading, spacing: 2) {
            HStack(alignment: .center, spacing: 4) {
                Text(viewModel.formatMessageHeader(message, colorScheme: colorScheme))
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
                if message.isPrivate && viewModel.isSelfMessage(message),
                   let status = message.deliveryStatus {
                    DeliveryStatusView(status: status)
                        .padding(.leading, 4)
                }
            }

            Group {
                switch media {
                case .voice(let url):
                    VoiceNoteView(
                        url: url,
                        isSending: state.isSending,
                        sendProgress: state.progress,
                        onCancel: cancelAction
                    )
                case .image(let url):
                    BlockRevealImageView(
                        url: url,
                        revealProgress: state.progress,
                        isSending: state.isSending,
                        onCancel: cancelAction,
                        initiallyBlurred: shouldBlurImage,
                        onOpen: {
                            if !state.isSending {
                                imagePreviewURL = url
                            }
                        },
                        onSave: {
                            saveMediaCopy(url: url)
                        },
                        onDelete: (!message.isPrivate && shouldBlurImage) ? { viewModel.deleteMediaMessage(messageID: message.id) } : nil
                    )
                    .frame(maxWidth: 280)
                }
            }
        }
        .padding(.vertical, 4)
    }

    private func mediaSendState(for message: BitchatMessage) -> (isSending: Bool, progress: Double?, canCancel: Bool) {
        let isOutgoing = media.url.path.contains("/outgoing/") || viewModel.isSelfMessage(message)
        guard isOutgoing else {
            return (false, nil, false)
        }

        var isSending = false
        var progress: Double?
        if let status = message.deliveryStatus {
            switch status {
            case .sending:
                isSending = true
                progress = 0
            case .partiallyDelivered(let reached, let total):
                if total > 0 {
                    isSending = true
                    progress = Double(reached) / Double(total)
                }
            case .sent, .read, .delivered, .failed:
                break
            }
        }
        let canCancel = isSending && isOutgoing
        let clamped = progress.map { max(0, min(1, $0)) }
        return (isSending, isSending ? clamped : nil, canCancel)
    }

    private func saveMediaCopy(url: URL) {
        #if os(iOS)
        exportMediaURL = url
        #else
        let panel = NSSavePanel()
        panel.canCreateDirectories = true
        panel.nameFieldStringValue = url.lastPathComponent
        panel.prompt = "save"
        if panel.runModal() == .OK, let destination = panel.url {
            do {
                if FileManager.default.fileExists(atPath: destination.path) {
                    try FileManager.default.removeItem(at: destination)
                }
                try FileManager.default.copyItem(at: url, to: destination)
            } catch {
                SecureLogger.error("Failed to save media copy: \(error)", category: .session)
            }
        }
        #endif
    }
}
