#if canImport(SwiftUI)
import SwiftUI

// MARK: - View Extension

extension View {
    /// Provides a Trebuchet connection to this view and its descendants.
    ///
    /// This is the primary way to add Trebuche connectivity to your SwiftUI app.
    ///
    /// ```swift
    /// @main
    /// struct MyApp: App {
    ///     var body: some Scene {
    ///         WindowGroup {
    ///             ContentView()
    ///                 .trebuche(transport: .webSocket(host: "api.example.com", port: 8080))
    ///         }
    ///     }
    /// }
    /// ```
    ///
    /// Child views can then access the connection via environment:
    ///
    /// ```swift
    /// struct ContentView: View {
    ///     @Environment(\.trebuchetConnection) var connection
    ///     // ...
    /// }
    /// ```
    ///
    /// - Parameters:
    ///   - transport: The transport configuration.
    ///   - reconnectionPolicy: Policy for automatic reconnection. Defaults to `.default`.
    ///   - autoConnect: Whether to connect automatically. Defaults to `true`.
    /// - Returns: A view with the connection available in the environment.
    public func trebuche(
        transport: TransportConfiguration,
        reconnectionPolicy: ReconnectionPolicy = .default,
        autoConnect: Bool = true
    ) -> some View {
        modifier(TrebuchetClientModifier(
            transport: transport,
            reconnectionPolicy: reconnectionPolicy,
            autoConnect: autoConnect
        ))
    }

    /// Provides a Trebuchet connection to this view and its descendants.
    ///
    /// - Parameters:
    ///   - transport: The transport configuration.
    ///   - reconnectionPolicy: Policy for automatic reconnection. Defaults to `.default`.
    ///   - autoConnect: Whether to connect automatically. Defaults to `true`.
    /// - Returns: A view with the connection available in the environment.
    @available(*, deprecated, renamed: "trebuche(transport:reconnectionPolicy:autoConnect:)")
    public func trebuchetClient(
        transport: TransportConfiguration,
        reconnectionPolicy: ReconnectionPolicy = .default,
        autoConnect: Bool = true
    ) -> some View {
        trebuche(transport: transport, reconnectionPolicy: reconnectionPolicy, autoConnect: autoConnect)
    }

    /// Switches to a different named connection within the current manager.
    ///
    /// Use this modifier in multi-server scenarios to specify which connection
    /// a view subtree should use.
    ///
    /// ```swift
    /// TrebuchetEnvironment(connections: [
    ///     "game": .webSocket(host: "game.example.com", port: 8080),
    ///     "chat": .webSocket(host: "chat.example.com", port: 8080)
    /// ]) {
    ///     TabView {
    ///         GameTab()  // Uses default connection
    ///         ChatTab().trebuchetConnection(name: "chat")
    ///     }
    /// }
    /// ```
    ///
    /// - Parameter name: The connection name to use.
    /// - Returns: A view using the specified connection.
    public func trebuchetConnection(name: String) -> some View {
        modifier(TrebuchetConnectionSwitchModifier(connectionName: name))
    }

    /// Executes an action when connection state changes.
    ///
    /// ```swift
    /// ContentView()
    ///     .onTrebuchetStateChange { state in
    ///         if state.isConnected {
    ///             loadInitialData()
    ///         }
    ///     }
    /// ```
    ///
    /// - Parameter action: The action to execute when state changes.
    /// - Returns: A view that observes connection state changes.
    public func onTrebuchetStateChange(
        perform action: @escaping (ConnectionState) -> Void
    ) -> some View {
        modifier(TrebuchetStateChangeModifier(action: action))
    }

    /// Shows alternative content when disconnected.
    ///
    /// ```swift
    /// GameView()
    ///     .whenDisconnected {
    ///         VStack {
    ///             ProgressView()
    ///             Text("Connecting...")
    ///         }
    ///     }
    /// ```
    ///
    /// - Parameter placeholder: The content to show when disconnected.
    /// - Returns: A view that shows placeholder content when disconnected.
    public func whenDisconnected<Placeholder: View>(
        @ViewBuilder placeholder: @escaping () -> Placeholder
    ) -> some View {
        modifier(TrebuchetDisconnectedModifier(placeholder: placeholder))
    }

    /// Shows alternative content when the connection is in a specific state.
    ///
    /// ```swift
    /// GameView()
    ///     .whenConnectionState(.connecting) {
    ///         ProgressView("Connecting...")
    ///     }
    /// ```
    ///
    /// - Parameters:
    ///   - targetState: The state to match.
    ///   - placeholder: The content to show when in the target state.
    /// - Returns: A view that shows placeholder content when in the target state.
    public func whenConnectionState<Placeholder: View>(
        _ targetState: ConnectionState,
        @ViewBuilder placeholder: @escaping () -> Placeholder
    ) -> some View {
        modifier(TrebuchetStateMatchModifier(targetState: targetState, placeholder: placeholder))
    }
}

// MARK: - Modifier Implementations

private struct TrebuchetClientModifier: ViewModifier {
    let transport: TransportConfiguration
    let reconnectionPolicy: ReconnectionPolicy
    let autoConnect: Bool

    @State private var connection: TrebuchetConnection?

    func body(content: Content) -> some View {
        content
            .environment(\.trebuchetConnection, connection)
            .task {
                let conn = TrebuchetConnection(
                    transport: transport,
                    reconnectionPolicy: reconnectionPolicy
                )
                connection = conn

                if autoConnect {
                    try? await conn.connect()
                }
            }
            .onDisappear {
                if let connection {
                    Task {
                        await connection.disconnect()
                    }
                }
            }
    }
}

private struct TrebuchetConnectionSwitchModifier: ViewModifier {
    let connectionName: String

    @Environment(\.trebuchetConnectionManager) private var manager

    func body(content: Content) -> some View {
        content
            .environment(\.trebuchetConnection, manager?[connectionName])
            .environment(\.trebuchetConnectionName, connectionName)
    }
}

private struct TrebuchetStateChangeModifier: ViewModifier {
    let action: (ConnectionState) -> Void

    @Environment(\.trebuchetConnection) private var connection

    func body(content: Content) -> some View {
        content
            .onChange(of: connection?.state) { _, newState in
                if let newState {
                    action(newState)
                }
            }
    }
}

private struct TrebuchetDisconnectedModifier<Placeholder: View>: ViewModifier {
    @ViewBuilder let placeholder: () -> Placeholder

    @Environment(\.trebuchetConnection) private var connection

    func body(content: Content) -> some View {
        if connection?.state.isConnected == true {
            content
        } else {
            placeholder()
        }
    }
}

private struct TrebuchetStateMatchModifier<Placeholder: View>: ViewModifier {
    let targetState: ConnectionState
    @ViewBuilder let placeholder: () -> Placeholder

    @Environment(\.trebuchetConnection) private var connection

    func body(content: Content) -> some View {
        if connection?.state == targetState {
            placeholder()
        } else {
            content
        }
    }
}
#endif
