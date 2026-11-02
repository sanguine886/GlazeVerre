@testable import CoreSSH
import XCTest

/// Unit tests for the shell-channel coordination primitives in CitadelTransport
/// (`OpenSignal`, `CallbackBox`) — pure lock logic that real connections would
/// otherwise leave uncovered.
final class OpenSignalTests: XCTestCase {
    func testSucceedBeforeWaitReturnsImmediately() async {
        let signal = OpenSignal()
        signal.succeed()
        try? await signal.wait() // must not hang
    }

    func testWaitResumesOnSucceed() async throws {
        let signal = OpenSignal()
        let waiter = Task { try await signal.wait() }
        try await Task.sleep(for: .milliseconds(20))
        signal.succeed()
        try await waiter.value
    }

    func testFailThrowsToPendingWaiter() async throws {
        let signal = OpenSignal()
        let waiter = Task { try await signal.wait() }
        try await Task.sleep(for: .milliseconds(20))
        signal.fail(SSHError.connectionFailed("boom"))

        do {
            _ = try await waiter.value
            XCTFail("Expected wait() to throw")
        } catch let error as SSHError {
            XCTAssertEqual(error, .connectionFailed("boom"))
        } catch {
            XCTFail("Unexpected error: \(error)")
        }
    }

    func testFirstSuccessWins() async throws {
        let signal = OpenSignal()
        signal.succeed()
        signal.fail(SSHError.connectionLost)
        try await signal.wait()
    }

    func testFirstFailureReachesLateWaiter() async {
        let signal = OpenSignal()
        signal.fail(SSHError.connectionFailed("boom"))
        signal.succeed()
        do {
            try await signal.wait()
            XCTFail("Expected stored failure")
        } catch {
            XCTAssertEqual(error as? SSHError, .connectionFailed("boom"))
        }
    }

    func testCallbackBoxSetGet() {
        let box = CallbackBox()
        XCTAssertNil(box.get())
        let callback: @Sendable () -> Void = {}
        box.set(callback)
        XCTAssertNotNil(box.get())
    }
}
