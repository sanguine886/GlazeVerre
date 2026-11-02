import CoreSSH
import Foundation

/// One sampled snapshot of a server's health, parsed from a short batch of
/// shell commands. History is kept per metric for the sparkline trend charts
/// (maidkit-style: 负载 / 内存 / 网络 / 磁盘 as the four headline metrics).
struct ServerMetrics: Sendable, Equatable {
    /// 1-minute load average from /proc/loadavg.
    var load1: Double
    /// Memory used / total (bytes), from `free -b`.
    var memoryUsed: UInt64
    var memoryTotal: UInt64
    /// Disk used / total on the root mount (bytes), from `df -B1 /`.
    var diskUsed: UInt64
    var diskTotal: UInt64
    /// Aggregate rx/tx delta since last sample (bytes/sec), from /proc/net/dev.
    var networkRxDelta: UInt64
    var networkTxDelta: UInt64
    /// Uptime seconds from /proc/uptime.
    var uptimeSeconds: UInt64

    var memoryPercent: Double {
        memoryTotal == 0 ? 0 : Double(memoryUsed) / Double(memoryTotal) * 100
    }

    var diskPercent: Double {
        diskTotal == 0 ? 0 : Double(diskUsed) / Double(diskTotal) * 100
    }
}

/// Collects metric snapshots over an SSH session. `sample()` runs a small batch
/// of read-only commands and parses the answers; it is safe to call repeatedly
/// to build trend history.
struct ServerMetricSampler {
    private let session: SSHSession
    /// Parsed cumulative rx/tx from the previous sample, for delta computation.
    private var lastNetRx: UInt64?
    private var lastNetTx: UInt64?
    /// Time (nanoseconds) of the previous sample, so rx/tx deltas get a rate.
    private var lastSampleNanos: UInt64?

    init(session: SSHSession) {
        self.session = session
    }

    /// Runs: `cat /proc/loadavg /proc/uptime; free -b; df -B1 /; cat /proc/net/dev`
    /// and parses the combined output (~5 commands, read-only, one round-trip).
    mutating func sample() async throws -> ServerMetrics {
        let script = """
        cat /proc/loadavg /proc/uptime; \
        free -b; \
        df -B1 / ; \
        cat /proc/net/dev
        """
        let result = try await session.run(script)
        let output = result.output

        let load1 = Self.firstNumber(after: "load avg:", in: output) ?? Self.firstNumber(after: "loadavg", in: output) ?? 0
        let uptimeSeconds = Self.firstNumber(after: "uptime", in: output) ?? 0
        let memoryUsed = Self.bytesAfter("Mem:", index: 1, in: output) ?? 0
        let memoryTotal = Self.bytesAfter("Mem:", index: 0, in: output) ?? 0
        let diskUsed = Self.bytesAfter("/dev/", index: 1, in: output) ?? 0
        let diskTotal = Self.bytesAfter("/dev/", index: 0, in: output) ?? 0
        let (rx, tx) = Self.ethBytes(in: output)

        let now = DispatchTime.now().uptimeNanoseconds
        let (rxDelta, txDelta): (UInt64, UInt64)
        if let lastRx = lastNetRx, let lastTx = lastNetTx, let lastNanos = lastSampleNanos, now > lastNanos {
            let elapsed = Double(now - lastNanos) / 1_000_000_000
            // Counters only ever grow — except across a reboot, an `ifdown`, or a
            // different interface winning the scan. Subtracting UInt64 the other
            // way round traps, so a decrease reads as "no traffic this tick".
            rxDelta = Self.rate(from: lastRx, to: rx, elapsed: elapsed)
            txDelta = Self.rate(from: lastTx, to: tx, elapsed: elapsed)
        } else {
            rxDelta = 0
            txDelta = 0
        }
        lastNetRx = rx
        lastNetTx = tx
        lastSampleNanos = now

        return ServerMetrics(
            load1: load1,
            memoryUsed: memoryUsed,
            memoryTotal: memoryTotal,
            diskUsed: diskUsed,
            diskTotal: diskTotal,
            networkRxDelta: rxDelta,
            networkTxDelta: txDelta,
            uptimeSeconds: UInt64(uptimeSeconds)
        )
    }

    // MARK: - Parsing helpers (POSIX-ish output)

    /// Bytes-per-second between two cumulative counter readings. A counter that
    /// went backwards (reboot / interface reset) yields 0 instead of trapping.
    static func rate(from previous: UInt64, to current: UInt64, elapsed: Double) -> UInt64 {
        guard elapsed > 0.001, current >= previous else { return 0 }
        return UInt64(Double(current - previous) / elapsed)
    }

    /// Finds the first decimal number after `marker` in `text`.
    static func firstNumber(after marker: String, in text: String) -> Double? {
        guard let range = text.range(of: marker) else { return nil }
        let tail = text[range.upperBound...]
        for line in tail.split(separator: "\n") {
            if let value = Double(line.trimmingCharacters(in: .whitespaces).split(separator: " ").first ?? "") {
                return value
            }
        }
        return nil
    }

    /// From a line like `Mem: 123 total 456 used ...` extracts the Nth number.
    static func bytesAfter(_ lineStart: String, index: Int, in text: String) -> UInt64? {
        guard let range = text.range(of: lineStart) else { return nil }
        let line = text[range.lowerBound...].split(separator: "\n").first ?? ""
        let tokens = line.split(separator: " ").compactMap { UInt64($0) }
        guard tokens.indices.contains(index) else { return nil }
        return tokens[index]
    }

    /// From `/proc/net/dev` extracts a real interface's rx/tx byte totals.
    /// Loopback is skipped (its traffic is not "network status"); the first
    /// non-`lo` device wins, and a short line is skipped rather than crashing.
    /// Defensively bounds-checked: a device line must carry at least 10
    /// whitespace tokens (index 9 = tx; shorter lines are skipped, never crash).
    static func ethBytes(in text: String) -> (rx: UInt64, tx: UInt64) {
        var loopback: (rx: UInt64, tx: UInt64)?
        for line in text.split(separator: "\n") where line.contains(":") {
            let cleaned = line.split(whereSeparator: \.isWhitespace)
            // [0]=iface, [1]=rxBytes, …, [9]=txBytes. Require the full column.
            guard cleaned.count > 9 else { continue }
            let rx = UInt64(cleaned[1].trimmingCharacters(in: .init(charactersIn: ":"))) ?? 0
            let tx = UInt64(cleaned[9]) ?? 0
            let name = cleaned[0].trimmingCharacters(in: .init(charactersIn: ":"))
            if name == "lo" {
                loopback = (rx, tx)
                continue
            }
            return (rx, tx)
        }
        return loopback ?? (0, 0)
    }
}
