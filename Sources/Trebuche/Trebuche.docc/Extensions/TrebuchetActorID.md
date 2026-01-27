# ``Trebuchet/TrebuchetActorID``

## Overview

Every distributed actor in Trebuchet has a unique `TrebuchetActorID`. This ID contains all the information needed to locate and communicate with the actor.

## Local vs Remote Actors

Actor IDs distinguish between local and remote actors:

```swift
// Local actor - no host/port
let localID = TrebuchetActorID(id: "my-actor")
localID.isLocal  // true

// Remote actor - includes host and port
let remoteID = TrebuchetActorID(id: "my-actor", host: "server.local", port: 8080)
remoteID.isRemote  // true
```

## Parsing Actor IDs

You can parse IDs from their string representation:

```swift
let id = TrebuchetActorID(parsing: "my-actor@server.local:8080")
// id.id == "my-actor"
// id.host == "server.local"
// id.port == 8080
```

## Topics

### Creating IDs

- ``init(id:)``
- ``init(id:host:port:)``
- ``init(parsing:)``

### Properties

- ``id``
- ``host``
- ``port``
- ``isLocal``
- ``isRemote``
- ``endpoint``
