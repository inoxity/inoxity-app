import SwiftUI

struct HealthSummaryCard: View {
    let title: String
    let symbol: String
    let rows: [(String, String)]
    var body: some View {
        InoxityCard {
            VStack(alignment: .leading, spacing: 12) {
                Label(title, systemImage: symbol).font(.headline).foregroundStyle(InoxityTheme.aqua)
                ForEach(Array(rows.enumerated()), id: \.offset) { _, row in
                    HStack(alignment: .top) {
                        Text(row.0).foregroundStyle(InoxityTheme.secondaryText)
                        Spacer(); Text(row.1).multilineTextAlignment(.trailing)
                    }.font(.subheadline)
                }
            }
        }
    }
}
