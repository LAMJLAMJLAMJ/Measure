#if canImport(Network)
import Foundation
import Network

private func remoteParameters() -> NWParameters {
    let tcp = NWProtocolTCP.Options()
    tcp.noDelay = true
    tcp.enableKeepalive = true
    tcp.keepaliveIdle = 5
    let parameters = NWParameters(tls: nil, tcp: tcp)
    parameters.includePeerToPeer = true
    return parameters
}

/// One connection between the Mac and a remote. Everything runs on the main queue.
@MainActor
public final class RemoteConnection {
    public enum Status: Equatable {
        case connecting, ready, closed(String?)
    }

    public let connection: NWConnection
    private var decoder = RemoteFrameDecoder()
    public private(set) var status: Status = .connecting

    public var onMessage: @MainActor (RemoteMessage) -> Void = { _ in }
    public var onStatus: @MainActor (Status) -> Void = { _ in }

    public init(connection: NWConnection) {
        self.connection = connection
    }

    public convenience init(endpoint: NWEndpoint) {
        self.init(connection: NWConnection(to: endpoint, using: remoteParameters()))
    }

    public func start() {
        connection.stateUpdateHandler = { [weak self] state in
            MainActor.assumeIsolated { self?.handle(state) }
        }
        connection.start(queue: .main)
        receive()
    }

    public func send(_ message: RemoteMessage) {
        guard status == .ready, let data = try? RemoteFraming.encode(message) else { return }
        connection.send(content: data, completion: .contentProcessed { _ in })
    }

    public func cancel() {
        connection.cancel()
        setStatus(.closed(nil))
    }

    private func handle(_ state: NWConnection.State) {
        switch state {
        case .ready: setStatus(.ready)
        case .failed(let error): connection.cancel(); setStatus(.closed(error.localizedDescription))
        case .waiting(let error): connection.cancel(); setStatus(.closed(error.localizedDescription))
        case .cancelled: setStatus(.closed(nil))
        default: break
        }
    }

    private func setStatus(_ new: Status) {
        if case .closed = status { return }
        status = new
        onStatus(new)
    }

    private func receive() {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 1 << 16) { [weak self] data, _, isComplete, error in
            MainActor.assumeIsolated {
                guard let self else { return }
                if let data, !data.isEmpty {
                    do {
                        for message in try self.decoder.append(data) { self.onMessage(message) }
                    } catch {
                        self.cancel()
                        return
                    }
                }
                if isComplete || error != nil {
                    self.cancel()
                } else {
                    self.receive()
                }
            }
        }
    }
}

/// Advertises the Mac over Bonjour and accepts remotes.
@MainActor
public final class RemoteServer {
    private var listener: NWListener?
    public private(set) var connections: [RemoteConnection] = []
    public private(set) var error: String?

    /// Called for each new connection once it is ready.
    public var onConnect: @MainActor (RemoteConnection) -> Void = { _ in }
    public var onMessage: @MainActor (RemoteCommand, RemoteConnection) -> Void = { _, _ in }
    public var onChange: @MainActor () -> Void = {}

    public init() {}

    public var isRunning: Bool { listener != nil }

    /// Starts advertising. `name` is the name the iPad shows; nil uses the computer's name.
    public func start(name: String? = nil) {
        guard listener == nil else { return }
        do {
            let listener = try NWListener(using: remoteParameters())
            listener.service = NWListener.Service(name: name, type: remoteServiceType)
            listener.newConnectionHandler = { [weak self] connection in
                MainActor.assumeIsolated { self?.accept(connection) }
            }
            listener.stateUpdateHandler = { [weak self] state in
                MainActor.assumeIsolated { self?.handle(state) }
            }
            listener.start(queue: .main)
            self.listener = listener
            error = nil
        } catch {
            self.error = error.localizedDescription
        }
        onChange()
    }

    public func stop() {
        listener?.cancel()
        listener = nil
        for connection in connections { connection.cancel() }
        connections = []
        onChange()
    }

    public func broadcast(_ message: RemoteMessage) {
        for connection in connections where connection.status == .ready {
            connection.send(message)
        }
    }

    private func handle(_ state: NWListener.State) {
        if case .failed(let failure) = state {
            error = failure.localizedDescription
            listener?.cancel()
            listener = nil
            onChange()
        }
    }

    private func accept(_ nwConnection: NWConnection) {
        let connection = RemoteConnection(connection: nwConnection)
        connection.onStatus = { [weak self, weak connection] status in
            guard let self, let connection else { return }
            switch status {
            case .ready: self.onConnect(connection)
            case .closed: self.connections.removeAll { $0 === connection }
            case .connecting: break
            }
            self.onChange()
        }
        connection.onMessage = { [weak self, weak connection] message in
            guard let self, let connection, case .command(let command) = message else { return }
            self.onMessage(command, connection)
        }
        connections.append(connection)
        connection.start()
    }
}

/// A Mac found on the network.
public struct RemoteHostEndpoint: Identifiable, Hashable {
    public var name: String
    public var endpoint: NWEndpoint
    public var id: String { name }
}

/// Looks for Macs running Measure.
@MainActor
public final class RemoteBrowser {
    private var browser: NWBrowser?
    public private(set) var hosts: [RemoteHostEndpoint] = []
    public private(set) var error: String?
    public var onChange: @MainActor () -> Void = {}

    public init() {}

    public func start() {
        guard browser == nil else { return }
        let browser = NWBrowser(for: .bonjour(type: remoteServiceType, domain: nil), using: remoteParameters())
        browser.browseResultsChangedHandler = { [weak self] results, _ in
            MainActor.assumeIsolated { self?.update(results) }
        }
        browser.stateUpdateHandler = { [weak self] state in
            MainActor.assumeIsolated { self?.handle(state) }
        }
        browser.start(queue: .main)
        self.browser = browser
    }

    public func stop() {
        browser?.cancel()
        browser = nil
    }

    /// Stops and starts again, which also brings back the local network prompt if it was missed.
    public func restart() {
        stop()
        hosts = []
        error = nil
        start()
        onChange()
    }

    private func update(_ results: Set<NWBrowser.Result>) {
        hosts = results.compactMap { result in
            guard case .service(let name, _, _, _) = result.endpoint else { return nil }
            return RemoteHostEndpoint(name: name, endpoint: result.endpoint)
        }
        .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
        onChange()
    }

    private func handle(_ state: NWBrowser.State) {
        switch state {
        case .failed(let failure), .waiting(let failure):
            error = failure.localizedDescription
            onChange()
        case .ready:
            if error != nil { error = nil; onChange() }
        default:
            break
        }
    }
}
#endif
