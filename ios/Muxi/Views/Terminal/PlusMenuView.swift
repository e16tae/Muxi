import SwiftUI

/// Context-dependent + menu shown as a SwiftUI Menu.
///
/// Normal mode: New Window, Split Horizontal, Split Vertical.
/// Session mode: New Session.
struct PlusMenuView: View {
    let isSessionMode: Bool

    var onNewWindow: (() -> Void)?
    var onSplitHorizontal: (() -> Void)?
    var onSplitVertical: (() -> Void)?
    var onNewSession: (() -> Void)?

    var body: some View {
        Menu {
            if isSessionMode {
                Button {
                    onNewSession?()
                } label: {
                    Text("New Session")
                }
            } else {
                Button {
                    onNewWindow?()
                } label: {
                    Text("New Window")
                }
                Button {
                    onSplitHorizontal?()
                } label: {
                    Text("Split Horizontal")
                }
                Button {
                    onSplitVertical?()
                } label: {
                    Text("Split Vertical")
                }
            }
        } label: {
            Image(systemName: "plus")
                .font(MuxiTokens.Typography.body)
                .foregroundStyle(MuxiTokens.Colors.accentDefault)
        }
    }
}
