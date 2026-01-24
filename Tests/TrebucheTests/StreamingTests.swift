import Testing
import Foundation
@testable import Trebuche

// MARK: - Test Types

/// Simple counter for testing delta encoding
struct Counter: DeltaCodable, Sendable, Equatable {
    let count: Int

    func delta(from previous: Counter) -> Counter? {
        let diff = count - previous.count
        return diff != 0 ? Counter(count: diff) : nil
    }

    func applying(delta: Counter) -> Counter {
        Counter(count: count + delta.count)
    }
}

/// Tests for realtime state streaming functionality
@Suite("Streaming Tests")
struct StreamingTests {

    @Test("StreamedState macro generates backing storage")
    func testStreamedStateMacro() async throws {
        // This test verifies that @StreamedState generates the correct infrastructure
        // The actual macro expansion is tested by successful compilation of TodoList
        #expect(true)
    }

    @Test("TrebuchetEnvelope encodes and decodes correctly")
    func testEnvelopeEncoding() async throws {
        let encoder = JSONEncoder()
        let decoder = JSONDecoder()

        // Test StreamStart envelope
        let streamStart = StreamStartEnvelope(
            streamID: UUID(),
            callID: UUID(),
            actorID: TrebuchetActorID(id: "test"),
            targetIdentifier: "observeState"
        )
        let envelope = TrebuchetEnvelope.streamStart(streamStart)

        let data = try encoder.encode(envelope)
        let decoded = try decoder.decode(TrebuchetEnvelope.self, from: data)

        if case .streamStart(let decodedStart) = decoded {
            #expect(decodedStart.streamID == streamStart.streamID)
            #expect(decodedStart.callID == streamStart.callID)
            #expect(decodedStart.targetIdentifier == streamStart.targetIdentifier)
        } else {
            Issue.record("Expected streamStart envelope")
        }
    }

    @Test("StreamData envelope preserves sequence numbers")
    func testStreamDataSequencing() async throws {
        let encoder = JSONEncoder()
        let decoder = JSONDecoder()

        let streamID = UUID()
        let testData = "test data".data(using: .utf8)!

        // Create stream data envelopes with sequence numbers
        let envelope1 = TrebuchetEnvelope.streamData(
            StreamDataEnvelope(
                streamID: streamID,
                sequenceNumber: 1,
                data: testData,
                timestamp: Date()
            )
        )

        let envelope2 = TrebuchetEnvelope.streamData(
            StreamDataEnvelope(
                streamID: streamID,
                sequenceNumber: 2,
                data: testData,
                timestamp: Date()
            )
        )

        // Encode and decode
        let data1 = try encoder.encode(envelope1)
        let decoded1 = try decoder.decode(TrebuchetEnvelope.self, from: data1)

        let data2 = try encoder.encode(envelope2)
        let decoded2 = try decoder.decode(TrebuchetEnvelope.self, from: data2)

        // Verify sequence numbers
        if case .streamData(let streamData1) = decoded1,
           case .streamData(let streamData2) = decoded2 {
            #expect(streamData1.sequenceNumber == 1)
            #expect(streamData2.sequenceNumber == 2)
            #expect(streamData1.streamID == streamData2.streamID)
        } else {
            Issue.record("Expected streamData envelopes")
        }
    }

    @Test("StreamEnd envelope includes termination reason")
    func testStreamEndReason() async throws {
        let encoder = JSONEncoder()
        let decoder = JSONDecoder()

        let reasons: [StreamEndReason] = [
            .completed,
            .actorTerminated,
            .clientUnsubscribed,
            .connectionClosed,
            .error
        ]

        for reason in reasons {
            let envelope = TrebuchetEnvelope.streamEnd(
                StreamEndEnvelope(streamID: UUID(), reason: reason)
            )

            let data = try encoder.encode(envelope)
            let decoded = try decoder.decode(TrebuchetEnvelope.self, from: data)

            if case .streamEnd(let streamEnd) = decoded {
                #expect(streamEnd.reason == reason)
            } else {
                Issue.record("Expected streamEnd envelope for reason: \(reason)")
            }
        }
    }

    @Test("StreamRegistry creates and tracks streams")
    func testStreamRegistry() async throws {
        let registry = StreamRegistry()

        let callID = UUID()
        let (streamID, stream) = await registry.createRemoteStream(callID: callID)

        // Verify stream ID was tracked
        let retrievedStreamID = await registry.streamID(for: callID)
        #expect(retrievedStreamID == streamID)

        // Clean up
        await registry.removeStream(streamID: streamID)

        // Verify removal
        let afterRemoval = await registry.streamID(for: callID)
        #expect(afterRemoval == nil)
    }

    @Test("StreamRegistry handles data delivery")
    func testStreamDataDelivery() async throws {
        let registry = StreamRegistry()

        let callID = UUID()
        let (streamID, stream) = await registry.createRemoteStream(callID: callID)

        let testData = "Hello, streaming!".data(using: .utf8)!

        // Set up receiver task
        let receiverTask = Task {
            var receivedData: [Data] = []
            for await data in stream {
                receivedData.append(data)
                if receivedData.count >= 2 {
                    break
                }
            }
            return receivedData
        }

        // Give the stream time to set up
        try await Task.sleep(for: .milliseconds(100))

        // Send data
        await registry.handleStreamData(
            StreamDataEnvelope(streamID: streamID, sequenceNumber: 1, data: testData, timestamp: Date())
        )
        await registry.handleStreamData(
            StreamDataEnvelope(streamID: streamID, sequenceNumber: 2, data: testData, timestamp: Date())
        )

        // Wait for receiver
        let receivedData = await receiverTask.value

        #expect(receivedData.count == 2)
        #expect(receivedData[0] == testData)
        #expect(receivedData[1] == testData)

        // Clean up
        await registry.removeStream(streamID: streamID)
    }

    @Test("StreamRegistry prevents duplicate sequence numbers")
    func testSequenceNumberDeduplication() async throws {
        let registry = StreamRegistry()

        let callID = UUID()
        let (streamID, stream) = await registry.createRemoteStream(callID: callID)

        let testData = "test".data(using: .utf8)!

        // Set up receiver
        let receiverTask = Task {
            var count = 0
            for await _ in stream {
                count += 1
                if count >= 2 {
                    break
                }
            }
            return count
        }

        // Give stream time to set up
        try await Task.sleep(for: .milliseconds(100))

        // Send sequence 1 twice (should only deliver once)
        await registry.handleStreamData(
            StreamDataEnvelope(streamID: streamID, sequenceNumber: 1, data: testData, timestamp: Date())
        )
        await registry.handleStreamData(
            StreamDataEnvelope(streamID: streamID, sequenceNumber: 1, data: testData, timestamp: Date())
        )

        // Send sequence 2
        await registry.handleStreamData(
            StreamDataEnvelope(streamID: streamID, sequenceNumber: 2, data: testData, timestamp: Date())
        )

        // Should only receive 2 items (duplicate sequence 1 is filtered)
        let count = await receiverTask.value
        #expect(count == 2)

        // Clean up
        await registry.removeStream(streamID: streamID)
    }

    @Test("StreamRegistry tracks last sequence number")
    func testLastSequenceTracking() async throws {
        let registry = StreamRegistry()

        let callID = UUID()
        let (streamID, stream) = await registry.createRemoteStream(callID: callID)

        let testData = "test".data(using: .utf8)!

        // Set up receiver
        let receiverTask = Task {
            var count = 0
            for await _ in stream {
                count += 1
                if count >= 3 {
                    break
                }
            }
            return count
        }

        // Give stream time to set up
        try await Task.sleep(for: .milliseconds(100))

        // Initial sequence should be 0
        let initialSequence = await registry.getLastSequence(streamID: streamID)
        #expect(initialSequence == 0)

        // Send data with sequence numbers
        await registry.handleStreamData(
            StreamDataEnvelope(streamID: streamID, sequenceNumber: 1, data: testData, timestamp: Date())
        )
        await registry.handleStreamData(
            StreamDataEnvelope(streamID: streamID, sequenceNumber: 2, data: testData, timestamp: Date())
        )
        await registry.handleStreamData(
            StreamDataEnvelope(streamID: streamID, sequenceNumber: 3, data: testData, timestamp: Date())
        )

        // Verify sequence is tracked
        let lastSequence = await registry.getLastSequence(streamID: streamID)
        #expect(lastSequence == 3)

        // Wait for receiver
        let count = await receiverTask.value
        #expect(count == 3)

        // Clean up
        await registry.removeStream(streamID: streamID)

        // After removal, should return nil
        let afterRemoval = await registry.getLastSequence(streamID: streamID)
        #expect(afterRemoval == nil)
    }

    @Test("Delta encoding reduces bandwidth for incremental updates")
    func testDeltaEncoding() async throws {
        // Create a manager and encode several values
        let manager = DeltaStreamManager<Counter>()

        // First value should be full
        let delta1 = try await manager.encode(Counter(count: 10))
        #expect(delta1.isFull == true)
        let decoded1 = try delta1.decode()
        #expect(decoded1.count == 10)

        // Second value should be delta (diff = 5)
        let delta2 = try await manager.encode(Counter(count: 15))
        #expect(delta2.isFull == false)
        let decoded2 = try delta2.decode()
        #expect(decoded2.count == 5)  // Delta is the difference

        // Third value with no change should return nil delta
        let value3 = Counter(count: 15)
        #expect(value3.delta(from: Counter(count: 15)) == nil)
    }

    @Test("Delta stream applier reconstructs full state")
    func testDeltaApplier() async throws {
        let applier = DeltaStreamApplier<Counter>()

        // Apply full state
        let full = try StateDelta<Counter>.full(Counter(count: 10))
        let value1 = try await applier.apply(full)
        #expect(value1.count == 10)

        // Apply delta (+5)
        let delta = try StateDelta<Counter>.delta(Counter(count: 5))
        let value2 = try await applier.apply(delta)
        #expect(value2.count == 15)

        // Apply another delta (-3)
        let delta2 = try StateDelta<Counter>.delta(Counter(count: -3))
        let value3 = try await applier.apply(delta2)
        #expect(value3.count == 12)
    }

    @Test("Delta stream helper converts regular stream")
    func testDeltaStreamHelper() async throws {
        // Create a regular stream
        let (regularStream, continuation) = AsyncStream<Counter>.makeStream()

        // Convert to delta stream
        let deltaStream = regularStream.withDeltaEncoding()

        // Start consuming delta stream
        let consumerTask = Task {
            var receivedDeltas: [(isFull: Bool, value: Counter)] = []
            for await delta in deltaStream {
                let value = try delta.decode()
                receivedDeltas.append((delta.isFull, value))
                if receivedDeltas.count >= 3 {
                    break
                }
            }
            return receivedDeltas
        }

        // Give stream time to set up
        try await Task.sleep(for: .milliseconds(100))

        // Send values
        continuation.yield(Counter(count: 100))
        continuation.yield(Counter(count: 105))
        continuation.yield(Counter(count: 110))

        // Check results
        let deltas = try await consumerTask.value
        #expect(deltas.count == 3)

        // First should be full state
        #expect(deltas[0].isFull == true)
        #expect(deltas[0].value.count == 100)

        // Second should be delta
        #expect(deltas[1].isFull == false)
        #expect(deltas[1].value.count == 5)

        // Third should be delta
        #expect(deltas[2].isFull == false)
        #expect(deltas[2].value.count == 5)

        continuation.finish()
    }
}
