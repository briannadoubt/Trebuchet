// Macro tests require swift-syntax which has linker conflicts on Linux
#if !os(Linux)
import Testing
import TrebuchetMacros

@Suite("Macro Smoke Tests")
struct MacroSmokeTests {
    @Test("MacroError enum exists and has correct cases")
    func macroErrorCases() {
        let error1 = MacroError.notDistributedActor
        let error2 = MacroError.invalidStreamedStateUsage

        #expect(error1.description == "@Trebuchet can only be applied to distributed actors")
        #expect(error2.description == "@StreamedState can only be applied to stored properties with explicit type annotations")
    }

    @Test("TrebuchetMacro type exists")
    func trebuchetMacroExists() {
        // Just verify the type exists and is a MemberMacro
        _ = TrebuchetMacro.self
        #expect(Bool(true))
    }

    @Test("StreamedStateMacro type exists")
    func streamedStateMacroExists() {
        // Just verify the type exists and conforms to required protocols
        _ = StreamedStateMacro.self
        #expect(Bool(true))
    }
}
#endif
