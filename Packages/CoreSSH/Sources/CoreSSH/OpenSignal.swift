import Foundation
import NIOConcurrencyHelpers

/// One-shot continuation gate signaled once the shell channel is live.
///
/// The first outcome wins and is *stored*: a waiter that arrives later sees
/// the same result the early waiter saw, so a failure that happened before
/// anyone waited cannot be silently dropped (ADR-0011).
final class OpenSignal: @unchecked Sendable {
    private let lock = NIOLock()
    private var waiters: [CheckedContinuation<Void, Error>] = []
    private var stored: Result<Void, Error>?

    func wait() async throws {
        try await withCheckedThrowingContinuation { continuation in
            let outcome = lock.withLock { () -> Result<Void, Error>? in
                if let stored {
                    return stored
                }
                waiters.append(continuation)
                return nil
            }
            if let outcome {
                continuation.resume(with: outcome)
            }
        }
    }

    func succeed() {
        settle(.success(()))
    }

    func fail(_ error: Error) {
        settle(.failure(error))
    }

    /// Records the outcome if nothing has settled the signal yet; a later
    /// outcome never overwrites the first one.
    private func settle(_ result: Result<Void, Error>) {
        let pending = lock.withLock { () -> [CheckedContinuation<Void, Error>] in
            guard stored == nil else { return [] }
            stored = result
            let pending = waiters
            waiters.removeAll()
            return pending
        }
        for waiter in pending {
            waiter.resume(with: result)
        }
    }
}
