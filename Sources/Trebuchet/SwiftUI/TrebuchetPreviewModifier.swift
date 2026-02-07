#if canImport(SwiftUI)
import SwiftUI

/// A preview modifier that provides a local Trebuchet server for SwiftUI previews.
///
/// This modifier uses the `.local` transport to provide in-process actor communication
/// with zero network overhead, perfect for SwiftUI previews and testing.
///
/// ## Usage with Custom PreviewModifier
///
/// Create a custom preview modifier with your own setup logic:
///
/// ```swift
/// struct GameRoomPreview: PreviewModifier {
///     static func makeSharedContext() async throws -> Void {
///         // Set up your actors - this runs once and is shared
///         let room = GameRoom(actorSystem: TrebuchetPreview.server.actorSystem)
///         await room.addPlayer(Player(name: "Alice"))
///         await room.addPlayer(Player(name: "Bob"))
///         await TrebuchetPreview.expose(room, as: "main-room")
///     }
///
///     func body(content: Content, context: Void) -> some View {
///         content.trebuchet(transport: .local)
///     }
/// }
///
/// #Preview("Game Room", traits: .modifier(GameRoomPreview())) {
///     GameView()
/// }
/// ```
///
/// ## Simple Usage with Trait
///
/// ```swift
/// #Preview("Simple", traits: .trebuchet) {
///     ContentView()
/// }
/// ```
///
/// ## Inline Setup
///
/// ```swift
/// #Preview {
///     GameView()
///         .trebuchet(transport: .local)
///         .task {
///             let room = GameRoom(actorSystem: TrebuchetPreview.server.actorSystem)
///             await TrebuchetPreview.expose(room, as: "main-room")
///         }
/// }
/// ```
///
@available(iOS 18.0, macOS 15.0, tvOS 18.0, watchOS 11.0, visionOS 2.0, *)
public struct TrebuchetPreviewModifier: PreviewModifier {
    public static func makeSharedContext() async throws -> Void {
        // Default implementation - users override in their own PreviewModifiers
    }

    public func body(content: Content, context: Void) -> some View {
        content.trebuchet(transport: .local)
    }
}

/// Helper for accessing the shared local server in previews.
///
/// `TrebuchetPreview` provides static access to the shared `LocalTransport.shared.server`
/// for easy actor exposure and configuration in SwiftUI previews.
///
/// ## Example Usage
///
/// ```swift
/// #Preview("Game Lobby") {
///     LobbyView()
///         .trebuchet(transport: .local)
///         .task {
///             let lobby = GameLobby(actorSystem: TrebuchetPreview.server.actorSystem)
///             await lobby.addPlayer(Player(name: "Alice"))
///             await TrebuchetPreview.expose(lobby, as: "lobby")
///         }
/// }
/// ```
@MainActor
public enum TrebuchetPreview {
    /// Access the shared local server for preview setup.
    public static var server: TrebuchetServer {
        LocalTransport.shared.server
    }

    /// Convenience method to expose actors in previews.
    ///
    /// - Parameters:
    ///   - actor: The distributed actor to expose
    ///   - name: The name to register the actor under
    public static func expose<Act: DistributedActor>(
        _ actor: Act,
        as name: String
    ) async where Act.ID == TrebuchetActorID {
        await server.expose(actor, as: name)
    }

    /// Convenience method to configure streaming in previews.
    ///
    /// - Parameters:
    ///   - protocolType: The protocol type to configure streaming for
    ///   - method: The method name to observe
    ///   - observe: The closure that returns a stream of state updates
    public static func configureStreaming<T, State: Codable & Sendable>(
        for protocolType: T.Type,
        method: String,
        observe: @escaping @Sendable (T) async -> AsyncStream<State>
    ) async {
        await server.configureStreaming(
            for: protocolType,
            method: method,
            observe: observe
        )
    }
}

/// Convenience preview trait for Trebuchet local transport.
@available(iOS 18.0, macOS 15.0, tvOS 18.0, watchOS 11.0, visionOS 2.0, *)
extension PreviewTrait where T == Preview.ViewTraits {
    /// Creates a preview trait with Trebuchet local transport configured.
    @MainActor
    public static var trebuchet: PreviewTrait<T> {
        .modifier(TrebuchetPreviewModifier())
    }
}
#endif
