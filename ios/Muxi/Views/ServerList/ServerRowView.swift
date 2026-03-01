import SwiftUI

struct ServerRowView: View {
    let server: Server

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(server.name)
                .font(.headline)
            Text("\(server.username)@\(server.host):\(server.port)")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding(.vertical, 4)
    }
}
