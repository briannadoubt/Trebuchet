#if canImport(SwiftUI)
import Distributed
import SwiftUI

/// The state of a remote actor resolution.
public enum RemoteActorState<Act: DistributedActor>: Sendable
where Act.ID == TrebuchetActorID, Act.ActorSystem == TrebuchetActorSystem {
    /// Not connected to a server.
    case disconnected

    /// Attempting to resolve the actor.
    case loading

    /// Actor successfully resolved.
    case resolved(Act)

    /// Resolution failed with an error.
    case failed(TrebuchetError)

    /// The resolved actor, if available.
    public var actor: Act? {
        if case .resolved(let actor) = self {
            return actor
        }
        return nil
    }

    /// Whether resolution is in progress.
    public var isLoading: Bool {
        if case .loading = self { return true }
        return false
    }

    /// The error, if resolution failed.
    public var error: TrebuchetError? {
        if case .failed(let error) = self {
            return error
        }
        return nil
    }

    /// Whether the actor is resolved and ready to use.
    public var isResolved: Bool {
        if case .resolved = self { return true }
        return false
    }
}

/// A property wrapper that manages remote actor resolution with automatic state handling.
///
/// `@RemoteActor` simplifies working with distributed actors in SwiftUI by automatically
/// handling connection state, actor resolution, and providing observable state for your views.
///
/// ## Basic Usage
///
/// ```swift
/// struct GameView: View {
///     @RemoteActor(id: "main-room") var room: GameRoom?
///
///     var body: some View {
///         if let room {
///             RoomView(room: room)
///         } else {
///             ProgressView("Connecting...")
///         }
///     }
/// }
/// ```
///
/// ## Using State for Detailed UI
///
/// Access the projected value (`$room`) to get detailed resolution state:
///
/// ```swift
/// struct GameView: View {
///     @RemoteActor(id: "main-room") var room: GameRoom?
///
///     var body: some View {
///         switch $room.state {
///         case .disconnected:
///             ContentUnavailableView(
///                 "Not Connected",
///                 systemImage: "wifi.slash"
///             )
///         case .loading:
///             ProgressView("Joining room...")
///         case .resolved(let room):
///             RoomView(room: room)
///         case .failed(let error):
///             ErrorView(error: error)
///         }
///     }
/// }
/// ```
///
/// ## Multi-Server Scenarios
///
/// Specify which connection to use:
///
/// ```swift
/// @RemoteActor(id: "general", connection: "chat")
/// var chatRoom: ChatRoom?
/// ```
@propertyWrapper
public struct RemoteActor<Act: DistributedActor>: DynamicProperty
where Act.ID == TrebuchetActorID, Act.ActorSystem == TrebuchetActorSystem {

    // MARK: - Configuration

    private let actorID: String
    private let connectionName: String?

    // MARK: - State

    @Environment(\.trebuchetConnection) private var connection
    @Environment(\.trebuchetConnectionManager) private var manager
    @Environment(\.trebuchetConnectionName) private var envConnectionName

    @SwiftUI.State private var resolvedActor: Act?
    @SwiftUI.State private var resolutionError: TrebuchetError?
    @SwiftUI.State private var isResolving = false
    @SwiftUI.State private var lastConnectionState: ConnectionState?

    // MARK: - Initialization

    /// Creates a remote actor wrapper with a specific ID.
    ///
    /// - Parameters:
    ///   - id: The actor ID as exposed by the server.
    ///   - connection: Optional connection name for multi-server scenarios.
    public init(id: String, connection: String? = nil) {
        self.actorID = id
        self.connectionName = connection
    }

    // MARK: - Property Wrapper

    /// The resolved actor, or nil if not yet resolved or resolution failed.
    @MainActor
    public var wrappedValue: Act? {
        resolvedActor
    }

    /// Access to the wrapper for state inspection and manual resolution.
    @MainActor
    public var projectedValue: RemoteActorProjection<Act> {
        RemoteActorProjection(
            state: state,
            resolve: { [self] in await self.resolveActor() },
            refresh: { [self] in await self.refreshActor() }
        )
    }

    // MARK: - Public API

    /// The current resolution state.
    @MainActor
    public var state: RemoteActorState<Act> {
        let effectiveConnection = resolveConnection()
        let currentConnectionState = effectiveConnection?.state

        // Handle connection state transitions
        handleConnectionStateChange(from: lastConnectionState, to: currentConnectionState)

        guard let conn = effectiveConnection else {
            return .disconnected
        }

        if !conn.state.isConnected {
            return .disconnected
        }

        if isResolving {
            return .loading
        }

        if let error = resolutionError {
            return .failed(error)
        }

        if let actor = resolvedActor {
            return .resolved(actor)
        }

        // Connected but not resolved yet - trigger auto-resolution
        triggerAutoResolution()
        return .loading
    }

    // MARK: - DynamicProperty

    nonisolated public mutating func update() {
        // DynamicProperty update is called by SwiftUI on the main thread
        // State observation happens through the `state` computed property
    }

    // MARK: - Auto-Resolution

    @SwiftUI.State private var resolutionTask: Task<Void, Never>?

    @MainActor
    private func handleConnectionStateChange(from oldState: ConnectionState?, to newState: ConnectionState?) {
        guard oldState != newState else { return }

        // Update tracked state (using a task to avoid mutating during view update)
        Task { @MainActor in
            lastConnectionState = newState
        }

        // If we just disconnected, clear the resolved actor
        if oldState?.isConnected == true && newState?.isConnected != true {
            Task { @MainActor in
                resolvedActor = nil
                resolutionError = nil
                resolutionTask?.cancel()
                resolutionTask = nil
            }
        }
    }

    @MainActor
    private func triggerAutoResolution() {
        // Don't start if already resolving or have a pending task
        guard !isResolving, resolutionTask == nil else { return }

        // Defer to next run loop to avoid modifying state during view update
        Task { @MainActor in
            guard self.resolutionTask == nil else { return }
            self.resolutionTask = Task { @MainActor in
                await self.resolveActor()
                self.resolutionTask = nil
            }
        }
    }

    // MARK: - Private

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
    private func resolveActor() async {
        guard let connection = resolveConnection(),
              connection.state.isConnected else {
            return
        }

        isResolving = true
        resolutionError = nil

        do {
            let actor = try connection.resolve(Act.self, id: actorID)
            resolvedActor = actor
        } catch let error as TrebuchetError {
            resolutionError = error
            resolvedActor = nil
        } catch {
            resolutionError = .remoteInvocationFailed(error.localizedDescription)
            resolvedActor = nil
        }

        isResolving = false
    }

    @MainActor
    private func refreshActor() async {
        resolvedActor = nil
        resolutionError = nil
        await resolveActor()
    }
}

/// Projection type for accessing remote actor state and methods.
@MainActor
public struct RemoteActorProjection<Act: DistributedActor>: Sendable
where Act.ID == TrebuchetActorID, Act.ActorSystem == TrebuchetActorSystem {
    /// The current resolution state.
    public let state: RemoteActorState<Act>

    private let _resolve: @Sendable @MainActor () async -> Void
    private let _refresh: @Sendable @MainActor () async -> Void

    init(
        state: RemoteActorState<Act>,
        resolve: @escaping @Sendable @MainActor () async -> Void,
        refresh: @escaping @Sendable @MainActor () async -> Void
    ) {
        self.state = state
        self._resolve = resolve
        self._refresh = refresh
    }

    /// Manually trigger actor resolution.
    public func resolve() async {
        await _resolve()
    }

    /// Invalidate and re-resolve the actor.
    public func refresh() async {
        await _refresh()
    }
}

// MARK: - Convenience View for Actor State

/// A view that displays content based on remote actor state.
///
/// This provides a convenient way to handle all resolution states:
///
/// ```swift
/// RemoteActorView(id: "main-room", type: GameRoom.self) { room in
///     RoomView(room: room)
/// } loading: {
///     ProgressView()
/// } disconnected: {
///     Text("Not connected")
/// } failed: { error in
///     Text("Error: \(error)")
/// }
/// ```
public struct RemoteActorView<Act: DistributedActor, Content: View, Loading: View, Disconnected: View, Failed: View>: View
where Act.ID == TrebuchetActorID, Act.ActorSystem == TrebuchetActorSystem {

    @RemoteActor private var actor: Act?

    private let content: (Act) -> Content
    private let loading: () -> Loading
    private let disconnected: () -> Disconnected
    private let failed: (TrebuchetError) -> Failed

    /// Creates a view that displays content based on remote actor state.
    ///
    /// - Parameters:
    ///   - id: The actor ID as exposed by the server.
    ///   - type: The type of the distributed actor.
    ///   - connection: Optional connection name for multi-server scenarios.
    ///   - content: Content to display when the actor is resolved.
    ///   - loading: Content to display while resolving.
    ///   - disconnected: Content to display when disconnected.
    ///   - failed: Content to display when resolution fails.
    public init(
        id: String,
        type: Act.Type,
        connection: String? = nil,
        @ViewBuilder content: @escaping (Act) -> Content,
        @ViewBuilder loading: @escaping () -> Loading,
        @ViewBuilder disconnected: @escaping () -> Disconnected,
        @ViewBuilder failed: @escaping (TrebuchetError) -> Failed
    ) {
        self._actor = RemoteActor(id: id, connection: connection)
        self.content = content
        self.loading = loading
        self.disconnected = disconnected
        self.failed = failed
    }

    public var body: some View {
        switch $actor.state {
        case .disconnected:
            disconnected()
        case .loading:
            loading()
        case .resolved(let actor):
            content(actor)
        case .failed(let error):
            failed(error)
        }
    }
}

// MARK: - Simplified Initializer

extension RemoteActorView where Loading == ProgressView<EmptyView, EmptyView>,
                               Disconnected == Text,
                               Failed == Text {

    /// Creates a view with default loading, disconnected, and error states.
    ///
    /// - Parameters:
    ///   - id: The actor ID as exposed by the server.
    ///   - type: The type of the distributed actor.
    ///   - connection: Optional connection name for multi-server scenarios.
    ///   - content: Content to display when the actor is resolved.
    public init(
        id: String,
        type: Act.Type,
        connection: String? = nil,
        @ViewBuilder content: @escaping (Act) -> Content
    ) {
        self._actor = RemoteActor(id: id, connection: connection)
        self.content = content
        self.loading = { ProgressView() }
        self.disconnected = { Text("Not Connected") }
        self.failed = { error in Text(verbatim: "Error: \(error)") }
    }
}
#endif
