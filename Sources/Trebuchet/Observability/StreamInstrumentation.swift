#if !os(WASI)
import Logging
import Metrics

/// Internal instrumentation hooks called by macro-generated code.
/// This keeps Logging/Metrics imports inside the Trebuchet module so
/// user code only needs `import Trebuchet`.
public enum TrebuchetStreamInstrumentation {
    private static let logger = Logger(label: "trebuchet.streaming")

    public static func streamSubscriptionStarted(
        property: String,
        actorID: String,
        streamID: String,
        subscriberCount: Int
    ) {
        logger.info("Stream subscription started", metadata: [
            "property": "\(property)",
            "actor_id": "\(actorID)",
            "stream_id": "\(streamID)",
            "subscriber_count": "\(subscriberCount)",
        ])
    }

    public static func stateChanged(property: String, subscriberCount: Int) {
        logger.debug("State changed", metadata: [
            "property": "\(property)",
            "subscribers": "\(subscriberCount)",
        ])
        Counter(label: "trebuchet_state_changes_total", dimensions: [
            ("property", property),
        ]).increment()
    }
}
#endif
