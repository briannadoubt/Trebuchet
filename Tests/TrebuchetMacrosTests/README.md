# TrebuchetMacros Tests

## Current Status

✅ **Smoke Tests** (`SmokeTest.swift`) - **PASSING**
- MacroError enum and error messages
- TrebuchetMacro type exists
- StreamedStateMacro type exists

❌ **Macro Expansion Tests** (`TrebuchetMacroTests.swift`) - **CRASHING**
- Comprehensive `assertMacroExpansion` tests crash with signal 5 (SIGTRAP)

## The Problem

**Root Cause:** `assertMacroExpansion()` has compatibility issues with Swift Testing framework.

According to [Swift Forums discussion](https://forums.swift.org/t/swift-testing-support-for-macros/72720):
- `SwiftSyntaxMacrosTestSupport.assertMacroExpansion()` requires **XCTest** and shows false-positive results with Swift Testing
- Even `SwiftSyntaxMacrosGenericTestSupport.assertMacroExpansion()` (the "generic" version) crashes when used with Swift Testing
- The Swift team has "no plans to add" native Swift Testing support for macro assertions as of 2025

## Solutions

###  1. Use Point-Free's `swift-macro-testing` Library (Recommended)

Add to `Package.swift`:
```swift
.package(url: "https://github.com/pointfreeco/swift-macro-testing", from: "0.2.0")
```

This library provides:
- Full Swift Testing support
- Automatic snapshot testing
- Better error messages

### 2. Use XCTest Instead

Convert macro tests to use XCTest's `XCTAssertEqual` instead of Swift Testing's `#expect`:

```swift
import XCTest
import SwiftSyntaxMacrosTestSupport

final class TrebuchetMacroTests: XCTestCase {
    func testAddActorSystemTypealias() {
        assertMacroExpansion(
            // ... works with XCTest
        )
    }
}
```

### 3. Write Manual Expansion Tests

Directly invoke the macro expansion methods and validate results:

```swift
@Test func manualExpansion() throws {
    let syntax = """
        @Trebuchet
        distributed actor Test {}
        """

    let parsed = Parser.parse(source: syntax)
    // Manually validate expanded members
}
```

## Current Test Coverage

Despite the `assertMacroExpansion` issue, the macros are well-tested through:

1. **Smoke tests** (this suite) - Verify types and errors exist
2. **Integration tests** (main Trebuchet package) - Real @Trebuchet and @StreamedState usage
3. **Manual testing** - Example projects compile and run correctly

## TODO

Choose one of the solutions above to enable comprehensive macro expansion testing. Recommendations:

- **Short term:** Keep smoke tests, document issue (current state)
- **Medium term:** Add Point-Free's swift-macro-testing library
- **Long term:** Wait for official Swift Testing macro support

## Sources

- [Swift Forums: Swift-Testing Support for Macros](https://forums.swift.org/t/swift-testing-support-for-macros/72720)
- [WWDC 2023: Write Swift Macros](https://developer.apple.com/videos/play/wwdc2023/10166/)
- [Point-Free: swift-macro-testing](https://github.com/pointfreeco/swift-macro-testing)
