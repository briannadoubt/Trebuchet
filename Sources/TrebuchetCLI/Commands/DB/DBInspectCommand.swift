import ArgumentParser
import Foundation

struct DBInspectCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "inspect",
        abstract: "Inspect shard contents, table schemas, and records"
    )

    @Option(name: .long, help: "Database root directory")
    var dbPath: String = ".trebuchet/db"

    @Argument(help: "Shard number to inspect")
    var shard: Int

    @Option(name: .long, help: "Table name to inspect")
    var table: String?

    @Option(name: .long, help: "Number of rows to show (default 10)")
    var limit: Int = 10

    @Flag(name: .long, help: "Show table schemas")
    var schema: Bool = false

    @Flag(name: .shortAndLong, help: "Enable verbose output")
    var verbose: Bool = false

    init() {}

    mutating func run() async throws {
        let terminal = Terminal()
        let shardDir = "\(dbPath)/shards/shard-\(String(format: "%04d", shard))"
        let dbFile = "\(shardDir)/main.sqlite"

        guard FileManager.default.fileExists(atPath: dbFile) else {
            terminal.print("Shard \(shard) not found at \(dbFile)", style: .error)
            throw ExitCode.failure
        }

        terminal.print("", style: .info)
        terminal.print("Inspecting shard-\(String(format: "%04d", shard))", style: .header)
        terminal.print("  Path: \(dbFile)", style: .dim)
        terminal.print("", style: .info)

        // List all tables with row counts
        let tablesOutput = try runSQLite(dbFile, sql: "SELECT name FROM sqlite_master WHERE type='table' AND name NOT LIKE 'sqlite_%' ORDER BY name;")
        let tableNames = tablesOutput.split(separator: "\n").map(String.init)

        if tableNames.isEmpty {
            terminal.print("  No tables found.", style: .dim)
            return
        }

        terminal.print("  Tables:", style: .info)
        for tableName in tableNames {
            let countOutput = try runSQLite(dbFile, sql: "SELECT COUNT(*) FROM \"\(tableName)\";")
            let count = countOutput.trimmingCharacters(in: .whitespacesAndNewlines)
            terminal.print("    \(tableName): \(count) rows", style: .info)
        }
        terminal.print("", style: .info)

        // Show schema if requested
        if schema {
            terminal.print("  Schemas:", style: .info)
            for tableName in tableNames {
                let schemaOutput = try runSQLite(dbFile, sql: "SELECT sql FROM sqlite_master WHERE name='\(tableName)';")
                terminal.print("", style: .info)
                terminal.print("    \(tableName):", style: .info)
                for line in schemaOutput.split(separator: "\n") {
                    terminal.print("      \(line)", style: .dim)
                }
            }
            terminal.print("", style: .info)
        }

        // Inspect specific table if requested
        if let table = table {
            guard tableNames.contains(table) else {
                terminal.print("  Table '\(table)' not found in shard \(shard).", style: .error)
                terminal.print("  Available tables: \(tableNames.joined(separator: ", "))", style: .dim)
                throw ExitCode.failure
            }

            terminal.print("  Records from '\(table)' (limit \(limit)):", style: .info)
            terminal.print("", style: .info)

            // Get column names
            let columnsOutput = try runSQLite(dbFile, sql: "PRAGMA table_info(\"\(table)\");")
            let columns = columnsOutput.split(separator: "\n").compactMap { line -> String? in
                let parts = line.split(separator: "|")
                return parts.count > 1 ? String(parts[1]) : nil
            }

            if !columns.isEmpty {
                terminal.print("    Columns: \(columns.joined(separator: ", "))", style: .dim)
                terminal.print("", style: .info)
            }

            // Fetch rows
            let rowsOutput = try runSQLite(dbFile, sql: "SELECT * FROM \"\(table)\" LIMIT \(limit);", mode: ".mode line")
            if rowsOutput.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                terminal.print("    (no rows)", style: .dim)
            } else {
                for line in rowsOutput.split(separator: "\n") {
                    terminal.print("    \(line)", style: .dim)
                }
            }
            terminal.print("", style: .info)
        }

        // Verbose: show SQLite stats
        if verbose {
            terminal.print("  SQLite Info:", style: .info)

            let pageSize = try runSQLite(dbFile, sql: "PRAGMA page_size;").trimmingCharacters(in: .whitespacesAndNewlines)
            let pageCount = try runSQLite(dbFile, sql: "PRAGMA page_count;").trimmingCharacters(in: .whitespacesAndNewlines)
            let journalMode = try runSQLite(dbFile, sql: "PRAGMA journal_mode;").trimmingCharacters(in: .whitespacesAndNewlines)
            let freePages = try runSQLite(dbFile, sql: "PRAGMA freelist_count;").trimmingCharacters(in: .whitespacesAndNewlines)

            terminal.print("    Page size: \(pageSize) bytes", style: .dim)
            terminal.print("    Page count: \(pageCount)", style: .dim)
            terminal.print("    Free pages: \(freePages)", style: .dim)
            terminal.print("    Journal mode: \(journalMode)", style: .dim)

            if let pages = Int(pageCount), let size = Int(pageSize) {
                let totalBytes = pages * size
                let mb = Double(totalBytes) / (1024 * 1024)
                terminal.print("    Database size: \(String(format: "%.2f", mb)) MB", style: .dim)
            }
            terminal.print("", style: .info)
        }
    }

    private func runSQLite(_ dbPath: String, sql: String, mode: String? = nil) throws -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/sqlite3")

        var args = [dbPath]
        if let mode = mode {
            args.append(mode)
        }
        args.append(sql)
        process.arguments = args

        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = Pipe()

        try process.run()
        process.waitUntilExit()

        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        return String(data: data, encoding: .utf8) ?? ""
    }
}
