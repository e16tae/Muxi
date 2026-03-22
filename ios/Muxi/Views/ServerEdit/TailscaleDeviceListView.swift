import SwiftUI

struct TailscaleDeviceListView: View {
    let accountManager: TailscaleAccountManager
    let onSelect: (TailscaleDevice) -> Void

    @State private var viewModel = TailscaleDeviceListViewModel()

    var body: some View {
        Group {
            if viewModel.isLoading && viewModel.devices.isEmpty {
                ProgressView("기기 목록 로딩 중...")
                    .frame(maxWidth: .infinity, minHeight: 100)
            } else if let error = viewModel.errorMessage, viewModel.devices.isEmpty {
                errorView(error)
            } else {
                searchField
                deviceList
            }
        }
        .task { await viewModel.fetch(accountManager: accountManager) }
        .refreshable { await viewModel.fetch(accountManager: accountManager) }
    }

    // MARK: - Search Field

    @ViewBuilder
    private var searchField: some View {
        TextField("기기 검색", text: $viewModel.searchText)
            .textInputAutocapitalization(.never)
            .autocorrectionDisabled()
            .padding(MuxiTokens.Spacing.sm)
            .background(MuxiTokens.Colors.surfaceRaised)
            .clipShape(RoundedRectangle(cornerRadius: MuxiTokens.Radius.sm))
            .padding(.horizontal, MuxiTokens.Spacing.lg)
            .padding(.vertical, MuxiTokens.Spacing.sm)
            .foregroundStyle(MuxiTokens.Colors.textPrimary)
    }

    // MARK: - Device List

    @ViewBuilder
    private var deviceList: some View {
        ForEach(viewModel.filteredDevices) { device in
            Button {
                onSelect(device)
            } label: {
                HStack {
                    VStack(alignment: .leading, spacing: MuxiTokens.Spacing.xs) {
                        Text(device.name)
                            .foregroundStyle(MuxiTokens.Colors.textPrimary)

                        if let ip = device.ipv4Address {
                            Text(ip)
                                .font(MuxiTokens.Typography.caption)
                                .foregroundStyle(MuxiTokens.Colors.textSecondary)
                        }
                    }

                    Spacer()

                    HStack(spacing: MuxiTokens.Spacing.sm) {
                        if let os = device.os {
                            Text(os)
                                .font(MuxiTokens.Typography.caption)
                                .foregroundStyle(MuxiTokens.Colors.textTertiary)
                        }

                        Circle()
                            .fill(device.isOnline ? MuxiTokens.Colors.success : MuxiTokens.Colors.textTertiary)
                            .frame(width: 8, height: 8)
                    }
                }
                .padding(.vertical, MuxiTokens.Spacing.xs)
            }
            .listRowBackground(MuxiTokens.Colors.surfaceDefault)
        }
    }

    // MARK: - Error View

    @ViewBuilder
    private func errorView(_ message: String) -> some View {
        VStack(spacing: MuxiTokens.Spacing.md) {
            Text(message)
                .foregroundStyle(MuxiTokens.Colors.error)
                .multilineTextAlignment(.center)

            Button("재시도") {
                Task { await viewModel.fetch(accountManager: accountManager) }
            }
            .foregroundStyle(MuxiTokens.Colors.accentDefault)
        }
        .frame(maxWidth: .infinity, minHeight: 100)
        .padding(MuxiTokens.Spacing.lg)
    }
}
