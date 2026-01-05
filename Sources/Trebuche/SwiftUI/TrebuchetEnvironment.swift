#if canImport(SwiftUI)
import SwiftUI

// MARK: - Environment Keys

private struct TrebuchetConnectionKey: EnvironmentKey {
    static let defaultValue: TrebuchetConnection? = nil
}

private struct TrebuchetConnectionManagerKey: EnvironmentKey {
    static let defaultValue: TrebuchetConnectionManager? = nil
}

private struct TrebuchetConnectionNameKey: EnvironmentKey {
    static let defaultValue: String? = nil
}

// MARK: - EnvironmentValues Extension

extension EnvironmentValues {
    /// The current Trebuchet connection.
    ///
    /// Access the connection in any view within a ``TrebuchetEnvironment``:
    ///
    /// ```swift
    /// struct MyView: View {
    ///     @Environment(\.trebuchetConnection) private var connection
    ///
    ///     var body: some View {
    ///         if connection?.state.isConnected == true {
    ///             Text("Connected!")
    ///         }
    ///     }
    /// }
    /// ```
    public var trebuchetConnection: TrebuchetConnection? {
        get { self[TrebuchetConnectionKey.self] }
        set { self[TrebuchetConnectionKey.self] = newValue }
    }

    /// The Trebuchet connection manager for multi-server scenarios.
    ///
    /// ```swift
    /// struct MyView: View {
    ///     @Environment(\.trebuchetConnectionManager) private var manager
    ///
    ///     var body: some View {
    ///         ForEach(manager?.connectionNames ?? [], id: \.self) { name in
    ///             ConnectionStatusRow(name: name)
    ///         }
    ///     }
    /// }
    /// ```
    public var trebuchetConnectionManager: TrebuchetConnectionManager? {
        get { self[TrebuchetConnectionManagerKey.self] }
        set { self[TrebuchetConnectionManagerKey.self] = newValue }
    }

    /// The currently active connection name (for multi-server scenarios).
    ///
    /// This is set automatically by ``TrebuchetEnvironment`` and can be
    /// overridden using the `.trebuchetConnection(name:)` modifier.
    public var trebuchetConnectionName: String? {
        get { self[TrebuchetConnectionNameKey.self] }
        set { self[TrebuchetConnectionNameKey.self] = newValue }
    }
}

// MARK: - TrebuchetEnvironment Container

/// A container view that provides Trebuchet connection(s) to the view hierarchy.
///
/// Use `TrebuchetEnvironment` at the root of your view hierarchy to make
/// connection state available to all child views.
///
/// ## Single Connection
///
/// ```swift
/// @main
/// struct MyApp: App {
///     var body: some Scene {
///         WindowGroup {
///             TrebuchetEnvironment(
///                 transport: .webSocket(host: "localhost", port: 8080)
///             ) {
///                 ContentView()
///             }
///         }
///     }
/// }
/// ```
///
/// ## Multiple Connections
///
/// ```swift
/// TrebuchetEnvironment(
///     connections: [
///         "game": .webSocket(host: "game.example.com", port: 8080),
///         "chat": .webSocket(host: "chat.example.com", port: 8080)
///     ],
///     defaultConnection: "game"
/// ) {
///     ContentView()
/// }
/// ```
///
/// ## Accessing in Child Views
///
/// ```swift
/// struct ContentView: View {
///     @Environment(\.trebuchetConnection) private var connection
///
///     var body: some View {
///         Text(connection?.state.isConnected == true ? "Online" : "Offline")
///     }
/// }
/// ```
public struct TrebuchetEnvironment<Content: View>: View {
    @State private var connection: TrebuchetConnection?
    @State private var manager: TrebuchetConnectionManager?
    @State private var connectTask: Task<Void, Never>?

    private let content: Content
    private let singleTransport: TransportConfiguration?
    private let multiTransports: [String: TransportConfiguration]?
    private let defaultConnectionName: String?
    private let reconnectionPolicy: ReconnectionPolicy
    private let autoConnect: Bool

    // MARK: - Single Connection Initializer

    /// Creates an environment with a single connection.
    ///
    /// - Parameters:
    ///   - transport: The transport configuration.
    ///   - reconnectionPolicy: Policy for automatic reconnection. Defaults to `.default`.
    ///   - autoConnect: Whether to connect automatically on appear. Defaults to `true`.
    ///   - content: The content view.
    public init(
        transport: TransportConfiguration,
        reconnectionPolicy: ReconnectionPolicy = .default,
        autoConnect: Bool = true,
        @ViewBuilder content: () -> Content
    ) {
        self.singleTransport = transport
        self.multiTransports = nil
        self.defaultConnectionName = nil
        self.reconnectionPolicy = reconnectionPolicy
        self.autoConnect = autoConnect
        self.content = content()
    }

    // MARK: - Multi-Connection Initializer

    /// Creates an environment with multiple named connections.
    ///
    /// - Parameters:
    ///   - connections: A dictionary mapping connection names to transport configurations.
    ///   - defaultConnection: The default connection name. Defaults to the first key.
    ///   - reconnectionPolicy: Policy for automatic reconnection. Defaults to `.default`.
    ///   - autoConnect: Whether to connect automatically on appear. Defaults to `true`.
    ///   - content: The content view.
    public init(
        connections: [String: TransportConfiguration],
        defaultConnection: String? = nil,
        reconnectionPolicy: ReconnectionPolicy = .default,
        autoConnect: Bool = true,
        @ViewBuilder content: () -> Content
    ) {
        self.singleTransport = nil
        self.multiTransports = connections
        self.defaultConnectionName = defaultConnection ?? connections.keys.sorted().first
        self.reconnectionPolicy = reconnectionPolicy
        self.autoConnect = autoConnect
        self.content = content()
    }

    public var body: some View {
        content
            .environment(\.trebuchetConnection, resolvedConnection)
            .environment(\.trebuchetConnectionManager, manager)
            .environment(\.trebuchetConnectionName, defaultConnectionName)
            .task {
                await setupConnections()
            }
            .onDisappear {
                connectTask?.cancel()
            }
    }

    private var resolvedConnection: TrebuchetConnection? {
        if let connection {
            return connection
        }
        if let manager, let name = defaultConnectionName {
            return manager[name]
        }
        return manager?.defaultConnection
    }

    @MainActor
    private func setupConnections() async {
        if let singleTransport {
            let conn = TrebuchetConnection(
                transport: singleTransport,
                reconnectionPolicy: reconnectionPolicy
            )
            connection = conn

            if autoConnect {
                try? await conn.connect()
            }
        } else if let multiTransports {
            let mgr = TrebuchetConnectionManager()
            manager = mgr

            // Apply the user-specified default connection name
            if let defaultConnectionName {
                mgr.defaultConnectionName = defaultConnectionName
            }

            if autoConnect {
                for (name, transport) in multiTransports.sorted(by: { $0.key < $1.key }) {
                    try? await mgr.addConnection(
                        named: name,
                        transport: transport,
                        reconnectionPolicy: reconnectionPolicy,
                        connectImmediately: true
                    )
                }
            } else {
                for (name, transport) in multiTransports.sorted(by: { $0.key < $1.key }) {
                    mgr.registerConnection(
                        named: name,
                        transport: transport,
                        reconnectionPolicy: reconnectionPolicy
                    )
                }
            }
        }
    }
}
#endif
