// Clock.swift
// Clock abstraction for testable time-based rate limiting

import Foundation

/// Clock protocol for time-based operations
public protocol Clock: Sendable {
    /// Returns the current date/time
    func now() -> Date
}

/// System clock using real time
public struct SystemClock: Clock {
    public init() {}

    public func now() -> Date {
        Date()
    }
}

/// Mock clock for testing with controllable time
public final class MockClock: Clock, @unchecked Sendable {
    private var currentTime: Date
    private let lock = NSLock()

    public init(startTime: Date = Date()) {
        self.currentTime = startTime
    }

    public func now() -> Date {
        lock.lock()
        defer { lock.unlock() }
        return currentTime
    }

    /// Advance time by the given interval
    public func advance(by interval: TimeInterval) {
        lock.lock()
        defer { lock.unlock() }
        currentTime = currentTime.addingTimeInterval(interval)
    }

    /// Set the current time
    public func set(time: Date) {
        lock.lock()
        defer { lock.unlock() }
        currentTime = time
    }
}
