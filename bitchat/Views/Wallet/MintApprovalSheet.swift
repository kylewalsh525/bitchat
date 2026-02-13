import SwiftUI

struct MintApprovalSheet: View {
    let mints: [String]
    let onCancel: () -> Void
    let onApprove: () -> Void

    var body: some View {
        NavigationStack {
            VStack(alignment: .leading, spacing: 14) {
                Text("Approve mint(s)?")
                    .font(.title3.weight(.semibold))
                Text("This action allows imports and payments using these mint URLs.")
                    .foregroundStyle(.secondary)
                    .font(.body)

                VStack(alignment: .leading, spacing: 6) {
                    ForEach(mints, id: \.self) { mint in
                        Text(mint)
                            .font(.system(.footnote, design: .monospaced))
                            .textSelection(.enabled)
                    }
                }
                .padding(.vertical, 8)
                .padding(.horizontal, 10)
                .background(
                    RoundedRectangle(cornerRadius: 12)
                        .fill(Color.secondary.opacity(0.12))
                )

                Spacer()
            }
            .padding()
            .navigationTitle("Mint Approval")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { onCancel() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Approve") { onApprove() }
                }
            }
        }
    }
}

