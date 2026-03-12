import Testing
@testable import Trebuchet

@Suite("Auto Transport Resolution Tests")
struct AutoTransportResolutionTests {

    @Test("Auto transport uses env host+port when both are present")
    func autoUsesEnvironmentOverride() throws {
        let config = TransportConfiguration.auto()
        let resolved = try config.resolved(environment: [
            "TREBUCHET_HOST": "dev.internal",
            "TREBUCHET_PORT": "9090",
        ])

        switch resolved {
        case .webSocket(let host, let port, _, _):
            #expect(host == "dev.internal")
            #expect(port == 9090)
        default:
            Issue.record("Expected resolved webSocket transport")
        }
    }

    @Test("Auto transport falls back to 127.0.0.1 when env is missing")
    func autoFallsBackToLoopbackIPv4() throws {
        let config = TransportConfiguration.auto()
        let resolved = try config.resolved(environment: [:])

        switch resolved {
        case .webSocket(let host, let port, _, _):
            #expect(host == "127.0.0.1")
            #expect(port == 8080)
        default:
            Issue.record("Expected resolved webSocket transport")
        }
    }

    @Test("Auto transport fails when fallback is disabled and env is incomplete")
    func autoFailsWhenFallbackDisabled() {
        let options = AutoTransportOptions(
            environmentHostKey: "TREBUCHET_HOST",
            environmentPortKey: "TREBUCHET_PORT",
            fallbackHost: "localhost",
            fallbackPort: 8080,
            allowLocalhostFallback: false
        )

        let config = TransportConfiguration.auto(options)
        do {
            _ = try config.resolved(environment: [
                "TREBUCHET_HOST": "example.com",
            ])
            Issue.record("Expected invalid configuration error")
        } catch let error as TrebuchetError {
            switch error {
            case .invalidConfiguration(let message):
                #expect(message.contains("TREBUCHET_HOST"))
                #expect(message.contains("TREBUCHET_PORT"))
            default:
                Issue.record("Expected invalid configuration error")
            }
        } catch {
            Issue.record("Expected TrebuchetError.invalidConfiguration, got \(error)")
        }
    }

    @Test("Auto transport fails on invalid env port")
    func autoFailsOnInvalidEnvPort() {
        let config = TransportConfiguration.auto()
        do {
            _ = try config.resolved(environment: [
                "TREBUCHET_HOST": "example.com",
                "TREBUCHET_PORT": "not-a-port",
            ])
            Issue.record("Expected invalid configuration error for bad port")
        } catch let error as TrebuchetError {
            switch error {
            case .invalidConfiguration(let message):
                #expect(message.contains("TREBUCHET_PORT"))
            default:
                Issue.record("Expected invalid configuration error")
            }
        } catch {
            Issue.record("Expected TrebuchetError.invalidConfiguration, got \(error)")
        }
    }
}
