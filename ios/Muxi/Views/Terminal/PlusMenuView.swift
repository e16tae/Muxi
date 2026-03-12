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
                    Label("New Session", systemImage: "plus.rectangle")
                }
            } else {
                Button {
                    onNewWindow?()
                } label: {
                    Label("New Window", systemImage: "macwindow.badge.plus")
                }
                Button {
                    onSplitHorizontal?()
                } label: {
                    Label("Split Horizontal", systemImage: "rectangle.split.1x2")
                }
                Button {
                    onSplitVertical?()
                } label: {
                    Label("Split Vertical", systemImage: "rectangle.split.2x1")
                }
            }
        } label: {
            Image(systemName: "plus")
                .font(MuxiTokens.Typography.body)
                .foregroundStyle(MuxiTokens.Colors.accentDefault)
        }
    }
}
