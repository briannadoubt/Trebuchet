import Foundation

/// Protocol for actors that provide streaming state
/// This is used internally by the server to access streams
public protocol StreamingActor: Actor {
    /// Get a stream of encoded data for a given property name
    /// This method internally calls the observe methods on the local actor
    func _getStream(for propertyName: String) async -> AsyncStream<Data>?
}
