# ``Trebuchet/TrebuchetConnection``

An observable connection wrapper with automatic reconnection support.

## Overview

`TrebuchetConnection` wraps ``TrebuchetClient`` with SwiftUI-compatible observation, providing reactive state updates and automatic reconnection with exponential backoff.

## Topics

### Creating a Connection

- ``init(transport:reconnectionPolicy:name:)``

### Connection Lifecycle

- ``connect()``
- ``disconnect()``
- ``state``
- ``connectedSince``

### Resolving Actors

- ``resolve(_:id:)``
- ``client``
- ``actorSystem``

### Configuration

- ``transportConfiguration``
- ``reconnectionPolicy``
- ``name``

### Error Handling

- ``lastError``
- ``reconnectionCount``

### Events

- ``events``
