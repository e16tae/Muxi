import Foundation
import os

@MainActor @Observable
final class TailscaleDeviceListViewModel {
    private let deviceService = TailscaleDeviceService()
    private let logger = Logger(subsystem: "com.muxi.app", category: "TailscaleDeviceListVM")

    var devices: [TailscaleDevice] = []
    var searchText: String = ""
    var isLoading = false
    var errorMessage: String?

    var filteredDevices: [TailscaleDevice] {
        if searchText.isEmpty { return devices }
        let query = searchText.lowercased()
        return devices.filter {
            $0.name.lowercased().contains(query) ||
            $0.addresses.contains(where: { $0.contains(query) })
        }
    }

    func fetch(accountManager: TailscaleAccountManager) async {
        guard let account = accountManager.account else { return }
        isLoading = true
        errorMessage = nil
        do {
            devices = try await deviceService.fetchDevices(account: account, accessToken: accountManager.accessToken(), apiKey: accountManager.apiKey())
            logger.info("Fetched \(self.devices.count) devices")
        } catch {
            errorMessage = error.localizedDescription
            logger.error("Device fetch failed: \(error)")
        }
        isLoading = false
    }
}
