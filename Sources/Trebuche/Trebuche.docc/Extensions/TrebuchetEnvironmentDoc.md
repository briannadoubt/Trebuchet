# ``Trebuchet/TrebuchetEnvironment``

A container view that provides Trebuchet connections to the view hierarchy.

## Overview

`TrebuchetEnvironment` is the primary way to integrate Trebuchet with SwiftUI. Place it at the root of your view hierarchy to make connection state available to all child views via the environment.

## Topics

### Single Connection

- ``init(transport:reconnectionPolicy:autoConnect:content:)``

### Multiple Connections

- ``init(connections:defaultConnection:reconnectionPolicy:autoConnect:content:)``
