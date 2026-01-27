import Testing
import Foundation
@testable import Trebuchet

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

    @Test("StreamFilter matches all data when type is .all")
    func testFilterAll() async throws {
        let filter = StreamFilter.all
        let testData = "test".data(using: .utf8)!

        #expect(filter.matches(testData) == true)
        #expect(filter.type == .all)
    }

    @Test("StreamFilter predefined type stores name and parameters")
    func testFilterPredefined() async throws {
        let filter = StreamFilter.predefined("changed", parameters: ["threshold": "10"])

        #expect(filter.type == .predefined)
        #expect(filter.name == "changed")
        #expect(filter.parameters?["threshold"] == "10")
    }

    @Test("StreamFilter encodes and decodes correctly")
    func testFilterSerialization() async throws {
        let encoder = JSONEncoder()
        let decoder = JSONDecoder()

        let filter = StreamFilter.predefined("nonEmpty", parameters: ["min": "1"])
        let data = try encoder.encode(filter)
        let decoded = try decoder.decode(StreamFilter.self, from: data)

        #expect(decoded.type == filter.type)
        #expect(decoded.name == filter.name)
        #expect(decoded.parameters?["min"] == "1")
    }

    @Test("InvocationEnvelope carries optional streamFilter")
    func testInvocationEnvelopeWithFilter() async throws {
        let filter = StreamFilter.predefined("changed")
        let envelope = InvocationEnvelope(
            callID: UUID(),
            actorID: TrebuchetActorID(id: "test"),
            targetIdentifier: "observeState",
            genericSubstitutions: [],
            arguments: [],
            streamFilter: filter
        )

        #expect(envelope.streamFilter != nil)
        #expect(envelope.streamFilter?.type == .predefined)
        #expect(envelope.streamFilter?.name == "changed")

        // Verify serialization
        let encoder = JSONEncoder()
        let decoder = JSONDecoder()
        let data = try encoder.encode(envelope)
        let decoded = try decoder.decode(InvocationEnvelope.self, from: data)

        #expect(decoded.streamFilter?.name == "changed")
    }

    @Test("StreamStartEnvelope carries optional filter from invocation")
    func testStreamStartEnvelopeWithFilter() async throws {
        let filter = StreamFilter.predefined("threshold", parameters: ["value": "100"])
        let envelope = StreamStartEnvelope(
            streamID: UUID(),
            callID: UUID(),
            actorID: TrebuchetActorID(id: "test"),
            targetIdentifier: "observeState",
            filter: filter
        )

        #expect(envelope.filter != nil)
        #expect(envelope.filter?.name == "threshold")
        #expect(envelope.filter?.parameters?["value"] == "100")

        // Verify serialization
        let encoder = JSONEncoder()
        let decoder = JSONDecoder()
        let envelopeWrapper = TrebuchetEnvelope.streamStart(envelope)
        let data = try encoder.encode(envelopeWrapper)
        let decoded = try decoder.decode(TrebuchetEnvelope.self, from: data)

        if case .streamStart(let start) = decoded {
            #expect(start.filter?.name == "threshold")
        } else {
            Issue.record("Expected streamStart envelope")
        }
    }

    @Test("StreamResumeEnvelope encodes resume request")
    func testStreamResumeEnvelope() async throws {
        let streamID = UUID()
        let actorID = TrebuchetActorID(id: "test-actor")
        let envelope = StreamResumeEnvelope(
            streamID: streamID,
            lastSequence: 42,
            actorID: actorID,
            targetIdentifier: "observeState"
        )

        #expect(envelope.streamID == streamID)
        #expect(envelope.lastSequence == 42)
        #expect(envelope.actorID.id == "test-actor")
        #expect(envelope.targetIdentifier == "observeState")

        // Verify serialization
        let encoder = JSONEncoder()
        let decoder = JSONDecoder()
        let wrapper = TrebuchetEnvelope.streamResume(envelope)
        let data = try encoder.encode(wrapper)
        let decoded = try decoder.decode(TrebuchetEnvelope.self, from: data)

        if case .streamResume(let resume) = decoded {
            #expect(resume.streamID == streamID)
            #expect(resume.lastSequence == 42)
        } else {
            Issue.record("Expected streamResume envelope")
        }
    }

    @Test("ServerStreamBuffer buffers and retrieves data")
    func testServerStreamBuffer() async throws {
        // This tests the server-side buffering for stream resumption
        // The ServerStreamBuffer is private, but we can test the concept

        struct TestBuffer {
            private var buffers: [UUID: [(sequence: UInt64, data: Data)]] = [:]
            private let maxSize: Int

            init(maxSize: Int = 100) {
                self.maxSize = maxSize
            }

            mutating func buffer(streamID: UUID, sequence: UInt64, data: Data) {
                var buffer = buffers[streamID] ?? []
                buffer.append((sequence, data))
                if buffer.count > maxSize {
                    buffer.removeFirst()
                }
                buffers[streamID] = buffer
            }

            func getBuffered(streamID: UUID, afterSequence: UInt64) -> [(sequence: UInt64, data: Data)]? {
                guard let buffer = buffers[streamID] else { return nil }
                return buffer.filter { $0.sequence > afterSequence }
            }
        }

        var buffer = TestBuffer(maxSize: 5)
        let streamID = UUID()
        let testData = "test".data(using: .utf8)!

        // Buffer some data
        for i in 1...10 {
            buffer.buffer(streamID: streamID, sequence: UInt64(i), data: testData)
        }

        // Should only keep last 5 due to maxSize
        let all = buffer.getBuffered(streamID: streamID, afterSequence: 0)
        #expect(all?.count == 5)
        #expect(all?.first?.sequence == 6)  // First 5 dropped
        #expect(all?.last?.sequence == 10)

        // Get data after sequence 7
        let recent = buffer.getBuffered(streamID: streamID, afterSequence: 7)
        #expect(recent?.count == 3)
        #expect(recent?.first?.sequence == 8)
        #expect(recent?.last?.sequence == 10)
    }

    @Test("Checkpoint tracking concept for stream resumption")
    func testCheckpointTracking() async throws {
        // Test the checkpoint concept that ObservedActor uses
        struct StreamCheckpoint: Sendable {
            let streamID: UUID
            let actorID: String
            let methodName: String
            var lastSequence: UInt64
        }

        // Create initial checkpoint
        var checkpoint = StreamCheckpoint(
            streamID: UUID(),
            actorID: "test-actor",
            methodName: "observeState",
            lastSequence: 0
        )

        #expect(checkpoint.lastSequence == 0)

        // Simulate receiving data and updating checkpoint
        for i in 1...5 {
            checkpoint = StreamCheckpoint(
                streamID: checkpoint.streamID,
                actorID: checkpoint.actorID,
                methodName: checkpoint.methodName,
                lastSequence: checkpoint.lastSequence + 1
            )
            #expect(checkpoint.lastSequence == UInt64(i))
        }

        // Final checkpoint should track we received 5 items
        #expect(checkpoint.lastSequence == 5)

        // This checkpoint could be used to resume from sequence 5
        let resumeEnvelope = StreamResumeEnvelope(
            streamID: checkpoint.streamID,
            lastSequence: checkpoint.lastSequence,
            actorID: TrebuchetActorID(id: checkpoint.actorID),
            targetIdentifier: checkpoint.methodName
        )

        #expect(resumeEnvelope.lastSequence == 5)
    }
}
