import SwiftUI

/// A single row in the session list, displaying the session name,
/// identifier, and window count.
struct SessionRowView: View {
    let session: TmuxSession

    var body: some View {
        HStack {
            VStack(alignment: .leading, spacing: 4) {
                Text(session.name)
                    .font(.headline)
                HStack(spacing: 8) {
                    Text(session.id)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    if !session.windows.isEmpty {
                        Text("\(session.windows.count) window\(session.windows.count == 1 ? "" : "s")")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            }
            Spacer()
            Image(systemName: "chevron.right")
                .font(.caption)
                .foregroundStyle(.tertiary)
        }
        .padding(.vertical, 4)
    }
}
