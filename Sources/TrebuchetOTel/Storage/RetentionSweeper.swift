import Foundation

public actor RetentionSweeper {
    private let store: SpanStore
    private let maxAge: Duration

    public init(store: SpanStore, maxAge: Duration) {
        self.store = store
        self.maxAge = maxAge
    }

    public func start() async {
        while !Task.isCancelled {
            try? await Task.sleep(for: .seconds(3600))
            let cutoffNano = Int64(Date().timeIntervalSince1970 * 1_000_000_000)
                - Int64(maxAge.components.seconds) * 1_000_000_000
            try? await store.deleteOlderThan(cutoffNano)
        }
    }
}
