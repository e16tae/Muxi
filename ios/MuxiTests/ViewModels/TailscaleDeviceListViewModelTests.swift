import Testing
import Foundation
@testable import Muxi

@Suite("TailscaleDeviceListViewModel")
@MainActor
struct TailscaleDeviceListViewModelTests {
    @Test("Initial state is idle")
    func initialState() {
        let vm = TailscaleDeviceListViewModel()
        #expect(vm.devices.isEmpty)
        #expect(vm.isLoading == false)
        #expect(vm.errorMessage == nil)
    }

    @Test("Search filters devices by name")
    func searchFilters() {
        let vm = TailscaleDeviceListViewModel()
        vm.devices = [
            TailscaleDevice(id: "1", name: "web-server", addresses: ["100.64.0.1"], isOnline: true, os: nil, lastSeen: nil),
            TailscaleDevice(id: "2", name: "db-server", addresses: ["100.64.0.2"], isOnline: true, os: nil, lastSeen: nil),
        ]
        vm.searchText = "web"
        #expect(vm.filteredDevices.count == 1)
        #expect(vm.filteredDevices[0].name == "web-server")
    }

    @Test("Empty search returns all devices")
    func emptySearchReturnsAll() {
        let vm = TailscaleDeviceListViewModel()
        vm.devices = [
            TailscaleDevice(id: "1", name: "web-server", addresses: ["100.64.0.1"], isOnline: true, os: nil, lastSeen: nil),
            TailscaleDevice(id: "2", name: "db-server", addresses: ["100.64.0.2"], isOnline: true, os: nil, lastSeen: nil),
        ]
        vm.searchText = ""
        #expect(vm.filteredDevices.count == 2)
    }

    @Test("Search filters by IP address")
    func searchByAddress() {
        let vm = TailscaleDeviceListViewModel()
        vm.devices = [
            TailscaleDevice(id: "1", name: "web-server", addresses: ["100.64.0.1"], isOnline: true, os: nil, lastSeen: nil),
            TailscaleDevice(id: "2", name: "db-server", addresses: ["100.64.0.2"], isOnline: true, os: nil, lastSeen: nil),
        ]
        vm.searchText = "0.2"
        #expect(vm.filteredDevices.count == 1)
        #expect(vm.filteredDevices[0].name == "db-server")
    }

    @Test("Search is case insensitive")
    func searchCaseInsensitive() {
        let vm = TailscaleDeviceListViewModel()
        vm.devices = [
            TailscaleDevice(id: "1", name: "Web-Server", addresses: ["100.64.0.1"], isOnline: true, os: nil, lastSeen: nil),
        ]
        vm.searchText = "WEB"
        #expect(vm.filteredDevices.count == 1)
    }
}
