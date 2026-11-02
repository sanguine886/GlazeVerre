@testable import CoreSSH
import Foundation
import XCTest

private final class SuspendedTransport: SSHTransport, @unchecked Sendable {
    let entered = OpenSignal()
    let release = OpenSignal()
    private let lock = NSLock()
    private let callback = CallbackBoxForTests()
    private var connected = false

    var onDrop: @Sendable () -> Void {
        get { callback.get() ?? {} }
        set { callback.set(newValue) }
    }

    var isConnected: Bool {
        lock.withLock { connected }
    }

    func open(config _: SSHHostConfig, validator _: TOFUHostKeyValidator) async throws {
        entered.succeed()
        try await release.wait()
        lock.withLock { connected = true }
    }

    func close() async {
        lock.withLock { connected = false }
    }

    func run(_ command: String) async throws -> String {
        command
    }

    func requestShell(cols _: Int, rows _: Int) async throws -> ShellStreams {
        throw SSHError.sessionNotConnected
    }

    func openSFTP() async throws -> any SFTPService {
        throw SSHError.sessionNotConnected
    }
}

private final class SuspendedFactory: SSHTransportMaking, @unchecked Sendable {
    private let lock = NSLock()
    private var index = 0
    let transports: [SuspendedTransport]

    init(_ transports: [SuspendedTransport]) {
        self.transports = transports
    }

    func makeTransport() -> any SSHTransport {
        lock.withLock {
            let transport = transports[min(index, transports.count - 1)]
            index += 1
            return transport
        }
    }

    var attempts: Int {
        lock.withLock { index }
    }
}

final class SSHSessionLifecycleTests: XCTestCase {
    private var config: SSHHostConfig {
        SSHHostConfig(host: "host", port: 22, username: "user", auth: .password("test"), keepaliveIntervalSeconds: 3600)
    }

    func testDisconnectDuringHandshakeClosesLateTransport() async throws {
        let transport = SuspendedTransport()
        let session = SSHSession(transportMaker: SuspendedFactory([transport]))
        let config = config
        let connect = Task { try await session.connect(config: config, knownHosts: KnownHostsStore(storeURL: nil)) }
        try await transport.entered.wait()
        await session.disconnect()
        transport.release.succeed()
        do {
            try await connect.value
            XCTFail("A closed handshake must not succeed")
        } catch {
            XCTAssertEqual(error as? SSHError, .cancelled)
        }
        let state = await session.state
        XCTAssertEqual(state, .closed)
        XCTAssertFalse(transport.isConnected)
    }

    func testStaleDropCannotReconnectNewConnection() async throws {
        let old = SuspendedTransport()
        let fresh = SuspendedTransport()
        old.release.succeed()
        fresh.release.succeed()
        let factory = SuspendedFactory([old, fresh])
        let session = SSHSession(transportMaker: factory,
                                 policy: ReconnectPolicy(maxAttempts: 1, baseDelaySeconds: 0, maxDelaySeconds: 0))
        let store = KnownHostsStore(storeURL: nil)
        try await session.connect(config: config, knownHosts: store)
        let staleDrop = old.onDrop
        await session.disconnect()
        try await session.connect(config: config, knownHosts: store)
        staleDrop()
        try await Task.sleep(for: .milliseconds(350))
        XCTAssertEqual(factory.attempts, 2)
        let state = await session.state
        XCTAssertEqual(state, .connected)
        await session.disconnect()
    }

    func testDisconnectDuringReconnectClosesLateTransport() async throws {
        let old = SuspendedTransport()
        let fresh = SuspendedTransport()
        old.release.succeed()
        let session = SSHSession(transportMaker: SuspendedFactory([old, fresh]),
                                 policy: ReconnectPolicy(maxAttempts: 1, baseDelaySeconds: 0, maxDelaySeconds: 0))
        try await session.connect(config: config, knownHosts: KnownHostsStore(storeURL: nil))
        old.onDrop()
        try await fresh.entered.wait()
        await session.disconnect()
        fresh.release.succeed()
        try await Task.sleep(for: .milliseconds(100))
        let state = await session.state
        XCTAssertEqual(state, .closed)
        XCTAssertFalse(fresh.isConnected)
    }
}
