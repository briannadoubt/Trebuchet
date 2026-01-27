# ``Trebuchet/ConnectionState``

Represents the current state of a Trebuchet connection.

## Overview

`ConnectionState` is an enum that tracks the lifecycle of a connection, from disconnected through connecting, connected, reconnecting, and failed states.

## Topics

### States

- ``disconnected``
- ``connecting``
- ``connected``
- ``reconnecting(attempt:)``
- ``failed(_:)``

### Inspecting State

- ``isConnected``
- ``isTransitioning``
- ``canConnect``
