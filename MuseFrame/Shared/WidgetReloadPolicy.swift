import Foundation

/// Leading refreshes are immediate; rapid writes share one trailing refresh.
struct WidgetReloadPolicy: Sendable {
    let minimumInterval: TimeInterval
    private(set) var lastRequestedAt: Date?

    init(minimumInterval: TimeInterval = 1) {
        self.minimumInterval = minimumInterval.isFinite ? max(0, minimumInterval) : 1
    }

    func delay(at date: Date) -> TimeInterval {
        guard let lastRequestedAt else { return 0 }
        // Clock adjustments must not postpone a metadata refresh for hours.
        return min(minimumInterval, max(0, minimumInterval - date.timeIntervalSince(lastRequestedAt)))
    }

    mutating func recordRequest(at date: Date) { lastRequestedAt = date }
}

#if !MUSEFRAME_WIDGET
@MainActor
final class WidgetReloadCoalescer {
    private var policy: WidgetReloadPolicy
    private let now: @MainActor () -> Date
    private let reload: @MainActor () -> Void
    private var pending: Task<Void, Never>?

    init(minimumInterval: TimeInterval = 1, now: @escaping @MainActor () -> Date = { .now },
         reload: @escaping @MainActor () -> Void) {
        policy = WidgetReloadPolicy(minimumInterval: minimumInterval)
        self.now = now
        self.reload = reload
    }

    deinit { pending?.cancel() }

    func request() {
        guard pending == nil else { return }
        let date = now()
        let delay = policy.delay(at: date)
        if delay <= 0 {
            policy.recordRequest(at: date)
            reload()
            return
        }
        pending = Task { [weak self] in
            do { try await Task.sleep(for: .seconds(delay)) }
            catch { return }
            guard !Task.isCancelled, let self else { return }
            self.pending = nil
            self.policy.recordRequest(at: self.now())
            self.reload()
        }
    }

    /// Used before the writer exits, so its final committed value gets a refresh request.
    func flush() {
        guard let pending else { return }
        pending.cancel()
        self.pending = nil
        policy.recordRequest(at: now())
        reload()
    }
}
#endif
