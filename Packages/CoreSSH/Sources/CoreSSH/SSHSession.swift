import Foundation

/// Lifecycle of one SSH session, observable via `stateStream()`.
public enum SSHSessionState: Equatable, Sendable {
    case idle
    case connecting
    case connected
    case reconnecting(attempt: Int)
    case failed(SSHError)
    case closed
}

public struct CommandResult: Equatable, Sendable {
    public let output: String
    public let durationSeconds: Double

    public init(output: String, durationSeconds: Double) {
        self.output = output
        self.durationSeconds = durationSeconds
    }
}

/// Production transport factory.
public struct CitadelTransportFactory: SSHTransportMaking {
    public init() {}

    public func makeTransport() -> any SSHTransport {
        CitadelTransport()
    }
}

public protocol SSHTransportMaking: Sendable {
    func makeTransport() -> any SSHTransport
}

/// Actor-isolated SSH session: connect, TOFU host-key handling, exec, shell,
/// keepalive and automatic reconnect with exponential backoff (spec §4.1/§4.2).
public actor SSHSession {
    public private(set) var state: SSHSessionState = .idle

    private let transportMaker: any SSHTransportMaking
    private let policy: ReconnectPolicy
    private var transport: (any SSHTransport)?
    private var config: SSHHostConfig?
    private var validator: TOFUHostKeyValidator?
    private var knownHosts: KnownHostsStore?
    private var keepaliveTask: Task<Void, Never>?
    private var reconnectTask: Task<Void, Never>?
    private var stateContinuations: [UUID: AsyncStream<SSHSessionState>.Continuation] = [:]
    private var userClosed = false
    /// Identifies the current connection lifecycle. Every connect/disconnect
    /// bumps it, so a handshake, reconnect or drop callback that belongs to an
    /// older lifecycle is ignored instead of resurrecting a dead session
    /// (ADR-0011).
    private var generation: UInt64 = 0

    public init(
        transportMaker: any SSHTransportMaking = CitadelTransportFactory(),
        policy: ReconnectPolicy = .standard
    ) {
        self.transportMaker = transportMaker
        self.policy = policy
    }

    /// Broadcast stream of state transitions; completes on `close()`.
    public func stateStream() -> AsyncStream<SSHSessionState> {
        let identifier = UUID()
        return AsyncStream { continuation in
            continuation.yield(state)
            self.stateContinuations[identifier] = continuation
            continuation.onTermination = { [weak self] _ in
                Task { await self?.removeStateContinuation(identifier) }
            }
        }
    }

    /// Opens the connection. First contact with an unpinned host throws
    /// `hostKeyUnknown`; a mismatched pinned key throws `hostKeyChanged` and the
    /// connection stays blocked until the user re-pins (spec §4.1).
    public func connect(config: SSHHostConfig, knownHosts: KnownHostsStore) async throws {
        guard state != .connected, state != .connecting else { return }
        userClosed = false
        self.config = config
        self.knownHosts = knownHosts

        let validator = TOFUHostKeyValidator(
            knownHosts: knownHosts,
            hostIdentifier: config.hostIdentifier
        )
        self.validator = validator

        generation &+= 1
        let attempt = generation
        setState(.connecting)
        do {
            try await openTransport(config: config, validator: validator, attempt: attempt)
            setState(.connected)
            startKeepalive()
        } catch {
            let mapped = Self.mapHostKeyError(error, validator: validator, knownHosts: knownHosts, config: config)
            // A disconnect during the handshake already published `.closed`;
            // do not overwrite it with a failure the user never caused.
            if attempt == generation {
                setState(.failed(mapped))
            }
            throw mapped
        }
    }

    /// Runs one command over a fresh exec channel.
    public func run(_ command: String) async throws -> CommandResult {
        guard let transport, case .connected = state else {
            throw SSHError.sessionNotConnected
        }
        let started = Date()
        let output = try await transport.run(command)
        return CommandResult(output: output, durationSeconds: Date().timeIntervalSince(started))
    }

    /// Requests an interactive shell (PTY, `xterm-256color`).
    public func requestShell(cols: Int = 80, rows: Int = 24) async throws -> ShellStreams {
        guard let transport, case .connected = state else {
            throw SSHError.sessionNotConnected
        }
        return try await transport.requestShell(cols: cols, rows: rows)
    }

    /// Opens an SFTP channel on the live connection (spec §4.4).
    public func openSFTP() async throws -> any SFTPService {
        guard let transport, case .connected = state else {
            throw SSHError.sessionNotConnected
        }
        return try await transport.openSFTP()
    }

    /// User-initiated close: no reconnects afterwards.
    public func disconnect() async {
        userClosed = true
        // Bump the generation so a handshake or reconnect that is still in
        // flight cannot install a transport after the user closed the session.
        generation &+= 1
        keepaliveTask?.cancel()
        keepaliveTask = nil
        reconnectTask?.cancel()
        reconnectTask = nil
        if let transport {
            await transport.close()
        }
        transport = nil
        setState(.closed)
    }

    // MARK: - Internals

    /// Package-internal view of the live transport (used by CoreSSHTests to
    /// simulate unexpected drops).
    var activeTransport: (any SSHTransport)? {
        transport
    }

    /// Opens a fresh transport for `attempt` and installs it as the live one.
    ///
    /// The transport's drop callback carries the generation it was opened
    /// under, so a drop from a superseded connection cannot trigger a
    /// reconnect on the current one.
    private func openTransport(
        config: SSHHostConfig,
        validator: TOFUHostKeyValidator,
        attempt: UInt64
    ) async throws {
        var fresh = transportMaker.makeTransport()
        fresh.onDrop = { [weak self] in
            Task { await self?.handleUnexpectedDrop(attempt: attempt) }
        }
        do {
            try await fresh.open(config: config, validator: validator)
        } catch {
            await fresh.close()
            throw error
        }
        // The handshake may have completed after the user disconnected or
        // after a newer connect took over; such a transport is stale and must
        // be closed instead of installed.
        guard attempt == generation, !userClosed else {
            await fresh.close()
            throw SSHError.cancelled
        }
        if let old = transport {
            await old.close()
        }
        transport = fresh
    }

    private func handleUnexpectedDrop(attempt: UInt64) {
        guard attempt == generation, !userClosed, case .connected = state else { return }
        keepaliveTask?.cancel()
        setState(.reconnecting(attempt: 0))
        reconnectTask = Task { [weak self] in
            guard let self else { return }
            await self.reconnectLoop(attempt: attempt)
        }
    }

    private func reconnectLoop(attempt: UInt64) async {
        guard let config, let validator else { return }

        var failures = 0
        while policy.shouldRetry(afterFailedAttempts: failures) {
            let delay = policy.delaySeconds(
                afterFailedAttempts: failures,
                jitterSeconds: Double.random(in: 0 ... 0.25)
            )
            try? await Task.sleep(for: .seconds(delay))
            if userClosed || attempt != generation {
                return
            }

            setState(.reconnecting(attempt: failures + 1))
            do {
                try await openTransport(config: config, validator: validator, attempt: attempt)
                setState(.connected)
                startKeepalive()
                return
            } catch {
                if userClosed || attempt != generation {
                    return
                }
                failures += 1
            }
        }
        if attempt == generation, !userClosed {
            setState(.failed(.connectionLost))
        }
    }

    private func startKeepalive() {
        keepaliveTask?.cancel()
        guard let config else { return }
        let interval = config.keepaliveIntervalSeconds
        keepaliveTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(interval))
                guard let self else { return }
                await sendKeepalive()
            }
        }
    }

    private func sendKeepalive() {
        guard case .connected = state, let transport else { return }
        let attempt = generation
        Task {
            do {
                _ = try await transport.run("true")
            } catch {
                handleUnexpectedDrop(attempt: attempt)
            }
        }
    }

    private func setState(_ newState: SSHSessionState) {
        state = newState
        for continuation in stateContinuations.values {
            continuation.yield(newState)
        }
    }

    private func removeStateContinuation(_ identifier: UUID) {
        stateContinuations[identifier] = nil
    }

    /// Translates a handshake failure into the TOFU errors the UI knows, using
    /// the fingerprint captured by the validator. Any other error passes through.
    static func mapHostKeyError(
        _ error: Error,
        validator: TOFUHostKeyValidator,
        knownHosts: KnownHostsStore,
        config: SSHHostConfig
    ) -> SSHError {
        let declined = (error as? SSHError) == .hostKeyVerificationDeclined
        guard declined, let presented = validator.presentedFingerprint() else {
            return (error as? SSHError) ?? .connectionFailed(error.localizedDescription)
        }
        switch knownHosts.verify(hostIdentifier: config.hostIdentifier, fingerprint: presented) {
        case .trusted:
            return .connectionFailed(error.localizedDescription)
        case .newHost:
            return .hostKeyUnknown(fingerprint: presented)
        case let .changed(pinned):
            return .hostKeyChanged(pinned: pinned, presented: presented)
        }
    }
}
