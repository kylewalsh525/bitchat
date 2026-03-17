import SwiftUI

struct MintApprovalSheet: View {
    let mints: [String]
    let onCancel: () -> Void
    let onApprove: () -> Void

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    Text("Approve mint(s)?")
                        .font(.title3.weight(.semibold))
                    Text("If you approve, this device can import and spend Cashu proofs from these mint URLs.")
                        .foregroundStyle(.secondary)
                        .font(.body)

                    VStack(alignment: .leading, spacing: 8) {
                        ForEach(mints, id: \.self) { mint in
                            Text(mint)
                                .font(.system(.footnote, design: .monospaced))
                                .textSelection(.enabled)
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }
                    }
                    .padding(.vertical, 10)
                    .padding(.horizontal, 12)
                    .background(
                        RoundedRectangle(cornerRadius: 12)
                            .fill(Color.secondary.opacity(0.12))
                    )
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(16)
            }
            .navigationTitle("Mint Approval")
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .safeAreaInset(edge: .bottom) {
                HStack(spacing: 12) {
                    Button("Cancel") { onCancel() }
                        .buttonStyle(.bordered)
                    Button("Approve") { onApprove() }
                        .buttonStyle(.borderedProminent)
                }
                .frame(maxWidth: .infinity, alignment: .trailing)
                .padding(.horizontal, 16)
                .padding(.top, 10)
                .padding(.bottom, 12)
                .background(.ultraThinMaterial)
            }
        }
#if os(iOS)
        .presentationDetents([.medium, .large])
#endif
    }
}
