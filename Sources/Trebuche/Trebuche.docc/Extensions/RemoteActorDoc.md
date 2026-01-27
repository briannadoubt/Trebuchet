# ``Trebuchet/RemoteActor``

A property wrapper for automatically resolving and managing remote actors.

## Overview

`@RemoteActor` provides the most ergonomic way to work with distributed actors in SwiftUI. It automatically handles connection state, actor resolution, and provides observable state for your views.

## Topics

### Creating a Remote Actor

- ``init(id:connection:)``

### Accessing the Actor

- ``wrappedValue``
- ``projectedValue``
- ``state``

### Resolution Control

- ``resolve()``
- ``refresh()``

### Resolution State

- ``State-swift.enum``
