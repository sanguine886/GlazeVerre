import Foundation
import Observation

/// Sampled metrics per host, kept for the life of the app process.
///
/// Re-opening a server used to show an empty "collecting…" panel until the first
/// 3-second sample landed; the cache renders the last known state instantly and
/// the live loop just continues the same history (真机反馈: 每次查看服务器不用
/// 重新加载状态). Process-lifetime only on purpose — metrics are worthless after
/// a relaunch, so nothing hits SwiftData.
@MainActor
@Observable
final class ServerMetricsCache {
    static let shared = ServerMetricsCache()

    /// History cap per host, so a long-running session stays bounded.
    static let historyLimit = 60

    private var histories: [UUID: [ServerMetrics]] = [:]

    private init() {}

    func history(for hostID: UUID) -> [ServerMetrics] {
        histories[hostID] ?? []
    }

    /// Appends one sample and returns the trimmed history for that host.
    func append(_ sample: ServerMetrics, for hostID: UUID) -> [ServerMetrics] {
        var history = histories[hostID] ?? []
        history.append(sample)
        if history.count > Self.historyLimit {
            history.removeFirst(history.count - Self.historyLimit)
        }
        histories[hostID] = history
        return history
    }
}
