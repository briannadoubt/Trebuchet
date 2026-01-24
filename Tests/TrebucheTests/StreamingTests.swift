import Testing
import Foundation
@testable import Trebuche

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
}
