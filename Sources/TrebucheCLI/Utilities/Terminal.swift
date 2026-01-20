import Foundation

/// Terminal output utilities with styling
public struct Terminal {
    public enum Style {
        case header
        case info
        case success
        case warning
        case error
        case dim

        var prefix: String {
            switch self {
            case .header: return ""
            case .info: return ""
            case .success: return "\u{001B}[32m"  // Green
            case .warning: return "\u{001B}[33m"  // Yellow
            case .error: return "\u{001B}[31m"    // Red
            case .dim: return "\u{001B}[90m"      // Gray
            }
        }

        var suffix: String {
            switch self {
            case .header, .info: return ""
            default: return "\u{001B}[0m"  // Reset
            }
        }
    }

    private let useColors: Bool

    public init(useColors: Bool = isatty(STDOUT_FILENO) == 1) {
        self.useColors = useColors
    }

    public func print(_ message: String, style: Style = .info, terminator: String = "\n") {
        if useColors {
            Swift.print("\(style.prefix)\(message)\(style.suffix)", terminator: terminator)
        } else {
            Swift.print(message, terminator: terminator)
        }
    }

    public func progressBar(current: Int, total: Int, width: Int = 30) -> String {
        let progress = Double(current) / Double(total)
        let filled = Int(progress * Double(width))
        let empty = width - filled

        let filledPart = String(repeating: "█", count: filled)
        let emptyPart = String(repeating: "░", count: empty)
        let percentage = Int(progress * 100)

        return "[\(filledPart)\(emptyPart)] \(percentage)%"
    }

    public func spinner(frame: Int) -> String {
        let frames = ["⠋", "⠙", "⠹", "⠸", "⠼", "⠴", "⠦", "⠧", "⠇", "⠏"]
        return frames[frame % frames.count]
    }
}

/// Flush stdout in a concurrency-safe way
@inline(__always)
nonisolated private func flushStdout() {
    #if canImport(Darwin)
    fflush(stdout)
    #else
    // On Linux, stdout is not concurrency-safe, use FileHandle instead
    FileHandle.standardOutput.synchronizeFile()
    #endif
}

/// Progress reporter for long-running operations
public actor ProgressReporter {
    private let terminal: Terminal
    private var currentTask: String = ""
    private var isRunning = false

    public init(terminal: Terminal = Terminal()) {
        self.terminal = terminal
    }

    public func start(_ task: String) {
        currentTask = task
        isRunning = true

        Task {
            var frame = 0
            while self.isRunning {
                let spinner = terminal.spinner(frame: frame)
                let task = self.currentTask
                print("\r\(spinner) \(task)...", terminator: "")
                flushStdout()
                frame += 1
                try? await Task.sleep(for: .milliseconds(100))
            }
        }
    }

    public func update(_ task: String) {
        currentTask = task
    }

    public func complete(_ message: String) {
        isRunning = false
        print("\r✓ \(message)                    ")
    }

    public func fail(_ message: String) {
        isRunning = false
        print("\r✗ \(message)                    ")
    }
}
