import MacroTesting
import Testing
import TrebuchetMacros

@Suite(
    "Trebuchet Macro Tests",
    .macros(
        [
            "Trebuchet": TrebuchetMacro.self,
            "StreamedState": StreamedStateMacro.self,
        ]
    )
)
struct TrebuchetMacroTests {

    // MARK: - @Trebuchet Macro Tests

    @Test("@Trebuchet adds ActorSystem typealias to distributed actor")
    func addActorSystemTypealias() {
        assertMacro {
            """
            @Trebuchet
            distributed actor GameRoom {
                distributed func join() {}
            }
            """
        } expansion: {
            """
            distributed actor GameRoom {
                distributed func join() {}

                public typealias ActorSystem = TrebuchetActorSystem
            }
            """
        }
    }

    @Test("@Trebuchet doesn't duplicate ActorSystem typealias if already present")
    func doesntDuplicateActorSystemTypealias() {
        assertMacro {
            """
            @Trebuchet
            distributed actor GameRoom {
                public typealias ActorSystem = TrebuchetActorSystem
                distributed func join() {}
            }
            """
        } expansion: {
            """
            distributed actor GameRoom {
                public typealias ActorSystem = TrebuchetActorSystem
                distributed func join() {}
            }
            """
        }
    }

    @Test("@Trebuchet fails on non-distributed actor")
    func failsOnNonDistributedActor() {
        assertMacro {
            """
            @Trebuchet
            actor RegularActor {
                func doSomething() {}
            }
            """
        } diagnostics: {
            """
            @Trebuchet
            ┬─────────
            ╰─ 🛑 @Trebuchet can only be applied to distributed actors
            actor RegularActor {
                func doSomething() {}
            }
            """
        }
    }

    @Test("@Trebuchet fails on non-actor types")
    func failsOnNonActorTypes() {
        assertMacro {
            """
            @Trebuchet
            struct MyStruct {
                var value: Int
            }
            """
        } diagnostics: {
            """
            @Trebuchet
            ┬─────────
            ╰─ 🛑 @Trebuchet can only be applied to distributed actors
            struct MyStruct {
                var value: Int
            }
            """
        }
    }

    @Test("@Trebuchet generates observe method for single @StreamedState property")
    func generatesSingleStreamObserveMethod() {
        assertMacro {
            """
            @Trebuchet
            distributed actor Counter {
                @StreamedState var count: Int = 0
            }
            """
        } expansion: {
            """
            distributed actor Counter {
                var count: Int {
                    get {
                        _count_storage
                    }
                    set {
                        _count_storage = newValue
                        _notifyCountChange()
                    }
                }

                private var _count_storage: Int  = 0

                private var _count_continuations: [UUID: AsyncStream<Int >.Continuation?] = [:]

                private func _notifyCountChange() {
                    for continuation in _count_continuations.values {
                        continuation?.yield(_count_storage)
                    }
                }

                public typealias ActorSystem = TrebuchetActorSystem

                public func observeCount() async -> AsyncStream<Int > {
                    let id = UUID()
                    _count_continuations[id] = nil // Reserve slot

                    return AsyncStream { continuation in
                        _count_continuations[id] = continuation
                        continuation.yield(_count_storage)

                        continuation.onTermination = { @Sendable [id, self] _ in
                            Task {
                                try? await self._cleanupCountContinuation(id)
                            }
                        }
                    }
                }

                private distributed func _cleanupCountContinuation(_ id: UUID) {
                    _count_continuations.removeValue(forKey: id)
                }

                /// Type-safe enum for streaming methods
                public enum StreamingMethod: String, Codable, Sendable, CaseIterable {
                        case observeCount
                }
            }
            """
        }
    }

    @Test("@Trebuchet generates no StreamingMethod enum when no @StreamedState properties")
    func noStreamingEnumWithoutStreamedState() {
        assertMacro {
            """
            @Trebuchet
            distributed actor SimpleActor {
                var regularProperty: String = ""
                distributed func doWork() {}
            }
            """
        } expansion: {
            """
            distributed actor SimpleActor {
                var regularProperty: String = ""
                distributed func doWork() {}

                public typealias ActorSystem = TrebuchetActorSystem
            }
            """
        }
    }

    // MARK: - @StreamedState Macro Tests

    @Test("@StreamedState generates backing storage with initial value")
    func generatesBackingStorageWithInitialValue() {
        assertMacro {
            """
            distributed actor Counter {
                @StreamedState var count: Int = 42
            }
            """
        } expansion: {
            """
            distributed actor Counter {
                var count: Int {
                    get {
                        _count_storage
                    }
                    set {
                        _count_storage = newValue
                        _notifyCountChange()
                    }
                }

                private var _count_storage: Int  = 42

                private var _count_continuations: [UUID: AsyncStream<Int >.Continuation?] = [:]

                private func _notifyCountChange() {
                    for continuation in _count_continuations.values {
                        continuation?.yield(_count_storage)
                    }
                }
            }
            """
        }
    }

    @Test("@StreamedState generates backing storage without initial value")
    func generatesBackingStorageWithoutInitialValue() {
        assertMacro {
            """
            distributed actor Container {
                @StreamedState var value: String
            }
            """
        } expansion: {
            """
            distributed actor Container {
                var value: String {
                    get {
                        _value_storage
                    }
                    set {
                        _value_storage = newValue
                        _notifyValueChange()
                    }
                }

                private var _value_storage: String

                private var _value_continuations: [UUID: AsyncStream<String>.Continuation?] = [:]

                private func _notifyValueChange() {
                    for continuation in _value_continuations.values {
                        continuation?.yield(_value_storage)
                    }
                }
            }
            """
        }
    }

    @Test("@StreamedState fails on property without type annotation")
    func failsOnPropertyWithoutTypeAnnotation() {
        assertMacro {
            """
            distributed actor Counter {
                @StreamedState var count = 0
            }
            """
        } diagnostics: {
            """
            distributed actor Counter {
                @StreamedState var count = 0
                ┬─────────────
                ├─ 🛑 @StreamedState can only be applied to stored properties with explicit type annotations
                ╰─ 🛑 @StreamedState can only be applied to stored properties with explicit type annotations
            }
            """
        }
    }

    @Test("@StreamedState handles complex types")
    func handlesComplexTypes() {
        assertMacro {
            """
            distributed actor TodoList {
                @StreamedState var items: [String] = []
            }
            """
        } expansion: {
            """
            distributed actor TodoList {
                var items: [String] {
                    get {
                        _items_storage
                    }
                    set {
                        _items_storage = newValue
                        _notifyItemsChange()
                    }
                }

                private var _items_storage: [String]  = []

                private var _items_continuations: [UUID: AsyncStream<[String] >.Continuation?] = [:]

                private func _notifyItemsChange() {
                    for continuation in _items_continuations.values {
                        continuation?.yield(_items_storage)
                    }
                }
            }
            """
        }
    }

    @Test("@StreamedState handles optional types")
    func handlesOptionalTypes() {
        assertMacro {
            """
            distributed actor UserSession {
                @StreamedState var currentUser: String? = nil
            }
            """
        } expansion: {
            """
            distributed actor UserSession {
                var currentUser: String? {
                    get {
                        _currentUser_storage
                    }
                    set {
                        _currentUser_storage = newValue
                        _notifyCurrentUserChange()
                    }
                }

                private var _currentUser_storage: String?  = nil

                private var _currentUser_continuations: [UUID: AsyncStream<String? >.Continuation?] = [:]

                private func _notifyCurrentUserChange() {
                    for continuation in _currentUser_continuations.values {
                        continuation?.yield(_currentUser_storage)
                    }
                }
            }
            """
        }
    }
}
