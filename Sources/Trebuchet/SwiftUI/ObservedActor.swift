#if canImport(SwiftUI)
import Distributed
import SwiftUI
import Foundation

/// A property wrapper that observes streaming state from a remote actor.
///
/// `@ObservedActor` automatically subscribes to a state stream from a distributed actor
/// and updates the view whenever new state is received.
///
/// ## Basic Usage
///
/// ```swift
/// struct TodoListView: View {
///     @ObservedActor("todos", observe: \TodoList.observeState)
///     var todoList
///
///     var body: some View {
///         if let state = todoList {
///             List(state.todos) { todo in
///                 Text(todo.title)
///             }
///         } else {
///             ProgressView("Loading...")
///         }
///     }
/// }
/// ```
///
/// ## Accessing the Actor
///
/// Use the projected value to access the actor reference for calling methods:
///
/// ```swift
/// Button("Add Todo") {
///     Task {
///         try? await $todoList.actor?.addTodo(title: "New Todo")
///     }
/// }
/// ```
@propertyWrapper
public struct ObservedActor<Act: DistributedActor, State: Codable & Sendable>: DynamicProperty
where Act.ID == TrebuchetActorID, Act.ActorSystem == TrebuchetActorSystem {

    // MARK: - Configuration

    private let actorID: String
    private let observeKeyPath: KeyPath<Act, () async -> AsyncStream<State>>?
    private let propertyName: String?
    private let connectionName: String?

    // MARK: - State

    @Environment(\.trebuchetConnection) private var connection
    @Environment(\.trebuchetConnectionManager) private var manager
    @Environment(\.trebuchetConnectionName) private var envConnectionName

    @SwiftUI.State private var resolvedActor: Act?
    @SwiftUI.State private var currentState: State?
    @SwiftUI.State private var resolutionError: TrebuchetError?
    @SwiftUI.State private var isResolving = false
    @SwiftUI.State private var lastConnectionState: ConnectionState?
    @SwiftUI.State private var streamTask: Task<Void, Never>?
    @SwiftUI.State private var resolutionTask: Task<Void, Never>?
    @SwiftUI.State private var streamCheckpoint: StreamCheckpoint?

    // MARK: - Initialization

    /// Creates an observed actor wrapper with a specific ID and observe method.
    ///
    /// - Parameters:
    ///   - id: The actor ID as exposed by the server.
    ///   - observe: Key path to the observe method that returns AsyncStream<State>.
    ///   - connection: Optional connection name for multi-server scenarios.
    public init(id: String, observe: KeyPath<Act, () async -> AsyncStream<State>>, connection: String? = nil) {
        self.actorID = id
        self.observeKeyPath = observe
        self.propertyName = nil
        self.connectionName = connection
    }

    /// Creates an observed actor wrapper with a specific ID and property name.
    ///
    /// This initializer uses the `_getStream` infrastructure to subscribe to state changes,
    /// which works reliably with distributed actors.
    ///
    /// - Parameters:
    ///   - id: The actor ID as exposed by the server.
    ///   - property: The property name to observe (e.g., "state" for observeState).
    ///   - connection: Optional connection name for multi-server scenarios.
    public init(id: String, property: String, connection: String? = nil) {
        self.actorID = id
        self.observeKeyPath = nil
        self.propertyName = property
        self.connectionName = connection
    }

    // MARK: - Property Wrapper

    /// The current state, or nil if not yet available.
    @MainActor
    public var wrappedValue: State? {
        currentState
    }

    /// Access to the wrapper for actor access and status inspection.
    @MainActor
    public var projectedValue: ObservedActorProjection<Act, State> {
        // Trigger connection state handling
        handleConnectionStateChange()

        let effectiveConnection = resolveConnection()
        let connectionState = effectiveConnection?.state ?? .disconnected

        return ObservedActorProjection(
            actor: resolvedActor,
            state: currentState,
            connectionState: connectionState,
            isConnecting: isResolving || (!connectionState.isConnected && resolvedActor == nil),
            error: resolutionError
        )
    }

    // MARK: - DynamicProperty

    nonisolated public mutating func update() {
        // DynamicProperty update is called by SwiftUI
        // Auto-resolution happens through the state computed property
    }

    // MARK: - Public Computed Property

    @MainActor
    private var effectiveConnectionState: (connection: TrebuchetConnection?, state: ConnectionState?) {
        let effectiveConnection = resolveConnection()
        return (effectiveConnection, effectiveConnection?.state)
    }

    // MARK: - Private

    @MainActor
    private func handleConnectionStateChange() {
        let (effectiveConnection, currentConnectionState) = effectiveConnectionState

        // Handle connection state changes
        if lastConnectionState != currentConnectionState {
            let wasDisconnected = lastConnectionState?.isConnected != true
            let isNowConnected = currentConnectionState?.isConnected == true

            // Defer state modifications to avoid modifying state during view update
            Task { @MainActor in
                lastConnectionState = currentConnectionState

                // If reconnecting and we have a checkpoint, try to resume
                if wasDisconnected && isNowConnected, let checkpoint = streamCheckpoint {
                    await attemptStreamResume(checkpoint: checkpoint)
                    return
                }

                // If disconnected, clean up all tasks and state (but keep checkpoint)
                if currentConnectionState?.isConnected != true {
                    streamTask?.cancel()
                    streamTask = nil
                    resolutionTask?.cancel()
                    resolutionTask = nil
                    resolvedActor = nil
                    currentState = nil
                    resolutionError = nil
                }
            }
            return
        }

        // If connected and not resolving, start resolution and subscription
        guard let connection = effectiveConnection,
              connection.state.isConnected,
              resolvedActor == nil,
              streamTask == nil,
              resolutionTask == nil else {
            return
        }

        // Defer all state modifications to avoid "modifying state during view update"
        Task { @MainActor in
            // Double-check conditions after async boundary
            guard resolvedActor == nil, streamTask == nil, resolutionTask == nil else {
                return
            }

            // Create and store the resolution task
            resolutionTask = Task { @MainActor in
                defer { resolutionTask = nil }

                isResolving = true
                resolutionError = nil

                do {
                    let actor = try connection.resolve(Act.self, id: actorID)
                    resolvedActor = actor

                    // Start streaming
                    startStreaming(actor: actor)
                } catch let error as TrebuchetError {
                    resolutionError = error
                } catch {
                    resolutionError = .remoteInvocationFailed(error.localizedDescription)
                }

                isResolving = false
            }
        }
    }

    @MainActor
    private func resolveConnection() -> TrebuchetConnection? {
        if let connectionName {
            return manager?[connectionName]
        }
        if let envName = envConnectionName, let manager {
            return manager[envName]
        }
        return connection
    }

    @MainActor
    private func attemptStreamResume(checkpoint: StreamCheckpoint) async {
        guard let connection = resolveConnection(),
              let client = connection.client,
              connection.state.isConnected else {
            return
        }

        resolutionTask = Task { @MainActor in
            defer { resolutionTask = nil }

            isResolving = true
            resolutionError = nil

            do {
                // Resolve actor
                let actor = try connection.resolve(Act.self, id: actorID)
                resolvedActor = actor

                // Create a resumed stream with the checkpoint's streamID
                let callID = UUID()
                let dataStream = await actor.actorSystem.streamRegistry.createResumedStream(
                    streamID: checkpoint.streamID,
                    callID: callID
                )

                // Send resume envelope to server
                let resume = StreamResumeEnvelope(
                    streamID: checkpoint.streamID,
                    lastSequence: checkpoint.lastSequence,
                    actorID: actor.id,
                    targetIdentifier: checkpoint.methodName
                )
                try await client.resumeStream(resume)

                // Transform data stream to typed stream and iterate
                streamTask = Task { @MainActor in
                    defer {
                        if streamTask?.isCancelled != false {
                            streamTask = nil
                        }
                    }

                    let decoder = JSONDecoder()
                    decoder.dateDecodingStrategy = .iso8601

                    var currentSequence = checkpoint.lastSequence

                    for await dataItem in dataStream {
                        guard !Task.isCancelled else { break }

                        do {
                            let value = try decoder.decode(State.self, from: dataItem)
                            currentState = value

                            // Update checkpoint sequence number
                            currentSequence += 1
                            streamCheckpoint = StreamCheckpoint(
                                streamID: checkpoint.streamID,
                                actorID: checkpoint.actorID,
                                methodName: checkpoint.methodName,
                                lastSequence: currentSequence
                            )
                        } catch {
                            // Decoding error - finish stream
                            if !Task.isCancelled {
                                resolutionError = .deserializationFailed(error)
                            }
                            break
                        }
                    }
                }

            } catch let error as TrebuchetError {
                resolutionError = error
                // Fall back to fresh stream start on error
                if let actor = resolvedActor {
                    startStreaming(actor: actor)
                }
            } catch {
                resolutionError = .remoteInvocationFailed(error.localizedDescription)
                // Fall back to fresh stream start on error
                if let actor = resolvedActor {
                    startStreaming(actor: actor)
                }
            }

            isResolving = false
        }
    }

    @MainActor
    private func startStreaming(actor: Act) {
        // Cancel any existing tasks before starting new ones
        streamTask?.cancel()
        streamTask = nil

        streamTask = Task { @MainActor in
            defer {
                // Always clean up the task reference when done
                if streamTask?.isCancelled != false {
                    streamTask = nil
                }
            }

            do {
                // Check for early cancellation
                guard !Task.isCancelled else { return }

                let stream: AsyncStream<State>
                let methodName: String

                let realStreamID: UUID
                if let keyPath = observeKeyPath {
                    // Use keypath approach (if it works)
                    let observeMethod = actor[keyPath: keyPath]
                    stream = await observeMethod()
                    // For keypath, we don't have a method name, use a placeholder
                    methodName = "observe"
                    // Keypath approach doesn't have access to stream ID
                    realStreamID = UUID()
                } else if let propertyName {
                    // Use the actor system's streaming infrastructure
                    // The observe method name follows the pattern: observe + PropertyName
                    methodName = "observe\(propertyName.prefix(1).uppercased())\(propertyName.dropFirst())"

                    // Create the invocation through the actor system
                    var encoder = actor.actorSystem.makeInvocationEncoder()

                    // Make a streaming remote call
                    let (streamID, dataStream) = try await actor.actorSystem.remoteCallStream(
                        on: actor,
                        target: RemoteCallTarget(methodName),
                        invocation: &encoder,
                        returning: State.self
                    )

                    // The dataStream is already typed as AsyncStream<State>
                    stream = dataStream
                    realStreamID = streamID
                } else {
                    throw TrebuchetError.remoteInvocationFailed("No observe method or property name specified")
                }

                // Initialize checkpoint for stream resumption
                streamCheckpoint = StreamCheckpoint(
                    streamID: realStreamID,
                    actorID: actorID,
                    methodName: methodName,
                    lastSequence: 0
                )

                // Iterate the stream and update state
                for await newState in stream {
                    guard !Task.isCancelled else {
                        break
                    }
                    currentState = newState

                    // Update checkpoint sequence number
                    if let checkpoint = streamCheckpoint {
                        streamCheckpoint = StreamCheckpoint(
                            streamID: checkpoint.streamID,
                            actorID: checkpoint.actorID,
                            methodName: checkpoint.methodName,
                            lastSequence: checkpoint.lastSequence + 1
                        )
                    }
                }
            } catch is CancellationError {
                // Task was cancelled - this is expected, don't set error
                return
            } catch let error as TrebuchetError {
                if !Task.isCancelled {
                    resolutionError = error
                }
            } catch {
                if !Task.isCancelled {
                    resolutionError = .remoteInvocationFailed(error.localizedDescription)
                }
            }
        }
    }

    /// Checkpoint state for stream resumption.
    struct StreamCheckpoint: Sendable {
        let streamID: UUID
        let actorID: String
        let methodName: String
        var lastSequence: UInt64
    }
}

/// Projection type for accessing observed actor and state.
@MainActor
public struct ObservedActorProjection<Act: DistributedActor, State: Codable & Sendable>: Sendable
where Act.ID == TrebuchetActorID, Act.ActorSystem == TrebuchetActorSystem {
    /// The resolved actor reference, or nil if not yet resolved.
    public let actor: Act?

    /// The current state, or nil if not yet available.
    public let state: State?

    /// The current connection state.
    public let connectionState: ConnectionState

    /// Whether currently connecting or resolving.
    public let isConnecting: Bool

    /// The last error that occurred, if any.
    public let error: TrebuchetError?

    init(
        actor: Act?,
        state: State?,
        connectionState: ConnectionState,
        isConnecting: Bool,
        error: TrebuchetError?
    ) {
        self.actor = actor
        self.state = state
        self.connectionState = connectionState
        self.isConnecting = isConnecting
        self.error = error
    }
}

#endif
