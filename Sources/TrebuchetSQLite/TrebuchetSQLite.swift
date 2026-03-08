/// TrebuchetSQLite - Local SQLite persistence for Trebuchet distributed actors.
///
/// SQLite is the local storage engine, Trebuchet handles distribution.
/// - Single server: actor → local GRDB pool → local SQLite file
/// - Multi-server: Trebuchet routes to owning node, same local write path
///
/// Uses GRDB as the Swift integration layer over SQLite.
@_exported import GRDB
@_exported import TrebuchetCloud
