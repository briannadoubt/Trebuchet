# ``Trebuchet/TrebuchetConnectionManager``

Manages multiple named connections for multi-server scenarios.

## Overview

Use `TrebuchetConnectionManager` when your app needs to communicate with multiple Trebuchet servers simultaneously. Each connection is identified by a unique name and can be accessed independently.

## Topics

### Creating a Manager

- ``init()``

### Managing Connections

- ``addConnection(named:transport:reconnectionPolicy:connectImmediately:)``
- ``registerConnection(named:transport:reconnectionPolicy:)``
- ``removeConnection(named:)``

### Connecting and Disconnecting

- ``connectAll()``
- ``disconnectAll()``
- ``connect(named:)``
- ``disconnect(named:)``

### Accessing Connections

- ``subscript(_:)``
- ``connections``
- ``connectionNames``
- ``defaultConnection``
- ``defaultConnectionName``

### Resolving Actors

- ``resolve(_:id:from:)``

### Connection Status

- ``allConnected``
- ``anyConnected``
