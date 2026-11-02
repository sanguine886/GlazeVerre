@testable import GlazeVerre
import XCTest

final class ServerMetricsTests: XCTestCase {
    func testEthBytesParsesFullDeviceLine() {
        // Standard /proc/net/dev line: iface rx… tx…
        let line = "eth0: 1000000 200 300 400 0 0 0 0 500000 100 0 0 0 0 0 0"
        let result = ServerMetricSampler.ethBytes(in: line)
        XCTAssertEqual(result.rx, 1_000_000)
        XCTAssertEqual(result.tx, 500_000)
    }

    func testEthBytesSkipsShortInterfaceLineWithoutCrash() {
        // A device line with fewer than 10 tokens (e.g. malformed or `lo`
        // with truncated counters) must be skipped, NOT crash (array bounds).
        let malformed = "lo: 0 0 0 0 0 0 0 0"
        let result = ServerMetricSampler.ethBytes(in: malformed)
        XCTAssertEqual(result.rx, 0)
        XCTAssertEqual(result.tx, 0)
    }

    func testEthBytesSkipsHeaderLine() {
        let header = "Inter-|   Receive                                |  Transmit"
        let result = ServerMetricSampler.ethBytes(in: header)
        XCTAssertEqual(result.rx, 0)
        XCTAssertEqual(result.tx, 0)
    }

    func testEthBytesPrefersRealInterfaceOverLoopback() {
        let dev = """
        lo: 999 1 0 0 0 0 0 0 999 1 0 0 0 0 0 0
        eth0: 1000000 200 300 400 0 0 0 0 500000 100 0 0 0 0 0 0
        """
        let result = ServerMetricSampler.ethBytes(in: dev)
        XCTAssertEqual(result.rx, 1_000_000, "loopback traffic is not the network metric")
        XCTAssertEqual(result.tx, 500_000)
    }

    func testEthBytesFallsBackToLoopbackWhenItIsTheOnlyDevice() {
        let dev = "lo: 999 1 0 0 0 0 0 0 777 1 0 0 0 0 0 0"
        let result = ServerMetricSampler.ethBytes(in: dev)
        XCTAssertEqual(result.rx, 999)
        XCTAssertEqual(result.tx, 777)
    }

    func testRateIsZeroWhenCountersGoBackwards() {
        // A reboot or `ifdown` resets the counter; UInt64 subtraction would trap.
        XCTAssertEqual(ServerMetricSampler.rate(from: 1_000_000, to: 10, elapsed: 3), 0)
        XCTAssertEqual(ServerMetricSampler.rate(from: 100, to: 400, elapsed: 3), 100)
        XCTAssertEqual(ServerMetricSampler.rate(from: 100, to: 400, elapsed: 0), 0)
    }

    func testFirstNumberAfterMarker() {
        XCTAssertEqual(ServerMetricSampler.firstNumber(after: "load avg:", in: "load avg: 1.25 0.75 0.5"), 1.25)
        XCTAssertNil(ServerMetricSampler.firstNumber(after: "nonexistent", in: "anything"))
    }

    func testBytesAfterMemLine() {
        let free = """
                  total        used        free      shared  buff/cache   available
        Mem:   1024000000    300000000   724000000      10000     100000000   700000000

        """
        XCTAssertEqual(ServerMetricSampler.bytesAfter("Mem:", index: 0, in: free), 1_024_000_000)
        XCTAssertEqual(ServerMetricSampler.bytesAfter("Mem:", index: 1, in: free), 300_000_000)
    }

    func testMemoryPercent() {
        let metrics = ServerMetrics(
            load1: 1.0,
            memoryUsed: 500_000_000,
            memoryTotal: 1_000_000_000,
            diskUsed: 200_000_000_000,
            diskTotal: 1_000_000_000_000,
            networkRxDelta: 0,
            networkTxDelta: 0,
            uptimeSeconds: 100
        )
        XCTAssertEqual(metrics.memoryPercent, 50.0, accuracy: 0.01)
        XCTAssertEqual(metrics.diskPercent, 20.0, accuracy: 0.01)
    }
}
