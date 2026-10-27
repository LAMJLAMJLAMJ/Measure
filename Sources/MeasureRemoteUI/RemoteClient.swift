#if canImport(SwiftUI) && canImport(Network)
import Foundation
import MeasureRemote
import Observation
#if canImport(UIKit)
import UIKit
#endif

/// Finds the Mac, keeps a connection to it and holds the latest state it sent.
@MainActor
@Observable
public final class RemoteClient {
    public private(set) var hosts: [RemoteHostEndpoint] = []
    /// The Mac the remote is connected to.
    public private(set) var connectedHost: String?
    /// The Mac the remote is connecting to.
    public private(set) var connectingHost: String?
    public private(set) var state: RemoteState?
    public private(set) var problem: String?

    @ObservationIgnored private let browser = RemoteBrowser()
    @ObservationIgnored private var connection: RemoteConnection?
    /// The Mac the user picked when more than one is on the network.
    @ObservationIgnored private var chosen: String?
    @ObservationIgnored private var retry: Task<Void, Never>?

    public init() {}

    public var isConnected: Bool { connectedHost != nil && state != nil }

    public func start() {
        browser.onChange = { [weak self] in self?.browserChanged() }
        browser.start()
    }

    /// Searches again from scratch, for the "Search Again" button.
    public func searchAgain() {
        disconnect()
        browser.restart()
    }

    public func connect(to host: RemoteHostEndpoint) {
        chosen = host.name
        disconnect()
        open(host)
    }

    /// Drops the connection and goes back to the list of Macs.
    public func disconnect() {
        retry?.cancel()
        let old = connection
        connection = nil
        old?.cancel()
        connectedHost = nil
        connectingHost = nil
        state = nil
    }

    /// Leaves the Mac while the app is in the background, so the Mac does not list a remote that
    /// is not looking.
    public func pause() {
        disconnect()
        browser.stop()
    }

    /// Looks for the Mac again on returning to the foreground.
    public func resume() {
        browser.restart()
        autoConnect()
    }

    public func forget() {
        chosen = nil
        disconnect()
    }

    public func send(_ command: RemoteCommand) {
        connection?.send(.command(command))
    }

    private func browserChanged() {
        hosts = browser.hosts
        if connection == nil { problem = browser.error }
        autoConnect()
    }

    private func autoConnect() {
        guard connection == nil else { return }
        let target: RemoteHostEndpoint?
        if let chosen {
            target = hosts.first { $0.name == chosen }
        } else {
            target = hosts.count == 1 ? hosts.first : nil
        }
        if let target { open(target) }
    }

    private func open(_ host: RemoteHostEndpoint) {
        let connection = RemoteConnection(endpoint: host.endpoint)
        self.connection = connection
        connectingHost = host.name
        connection.onStatus = { [weak self, weak connection] status in
            guard let self, let connection, connection === self.connection else { return }
            switch status {
            case .ready:
                self.connectingHost = nil
                self.connectedHost = host.name
                self.problem = nil
                connection.send(.command(.hello(device: Self.deviceName, version: remoteProtocolVersion)))
            case .closed(let reason):
                self.connection = nil
                self.connectedHost = nil
                self.connectingHost = nil
                self.state = nil
                if let reason { self.problem = reason }
                self.scheduleRetry()
            case .connecting:
                break
            }
        }
        connection.onMessage = { [weak self, weak connection] message in
            guard let self, let connection, connection === self.connection,
                  case .state(let state) = message else { return }
            self.state = state
        }
        connection.start()
    }

    private func scheduleRetry() {
        retry?.cancel()
        retry = Task { [weak self] in
            try? await Task.sleep(for: .seconds(2))
            guard !Task.isCancelled else { return }
            self?.autoConnect()
        }
    }

    private static var deviceName: String {
        #if canImport(UIKit)
        return UIDevice.current.name
        #else
        return ProcessInfo.processInfo.hostName
        #endif
    }
}
#endif
