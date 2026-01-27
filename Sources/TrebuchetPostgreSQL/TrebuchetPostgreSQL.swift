import Foundation

/// # TrebuchetPostgreSQL
///
/// PostgreSQL integration for Trebuchet distributed actors.
///
/// This module provides:
/// - **PostgreSQLStateStore**: Actor state persistence using PostgreSQL
/// - **PostgreSQLStreamAdapter**: Multi-instance synchronization via LISTEN/NOTIFY
///
/// ## Features
///
/// ### State Persistence
///
/// Store actor state in PostgreSQL with automatic sequence tracking and optimistic locking.
///
/// ### Multi-Instance Synchronization
///
/// Use PostgreSQL's LISTEN/NOTIFY to synchronize state changes across multiple actor instances:
/// - Real-time notifications when state changes
/// - No external pub/sub infrastructure needed
/// - Transactional guarantees
///
/// ## Quick Start
///
/// ```swift
/// import TrebuchetPostgreSQL
///
/// // Initialize state store
/// let stateStore = try await PostgreSQLStateStore(
///     host: "localhost",
///     port: 5432,
///     database: "mydb",
///     username: "postgres",
///     password: "password"
/// )
///
/// // Initialize stream adapter for multi-instance sync
/// let streamAdapter = try await PostgreSQLStreamAdapter(
///     host: "localhost",
///     port: 5432,
///     database: "mydb",
///     username: "postgres",
///     password: "password",
///     channel: "actor_state_changes"
/// )
///
/// // Use with StatefulActor
/// let actor = try await MyActor(
///     actorSystem: system,
///     stateStore: stateStore,
///     streamAdapter: streamAdapter
/// )
/// ```
///
/// ## Database Setup
///
/// See ``PostgreSQLStateStore`` and ``PostgreSQLStreamAdapter`` for schema setup instructions.
///
/// ## Topics
///
/// ### State Storage
///
/// - ``PostgreSQLStateStore``
///
/// ### Multi-Instance Synchronization
///
/// - ``PostgreSQLStreamAdapter``
/// - ``StateChangeNotification``
///
@_exported import Trebuchet
@_exported import TrebuchetCloud
