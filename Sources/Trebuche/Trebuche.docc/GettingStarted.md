# Getting Started with Trebuche

Learn how to create distributed actors that communicate across network boundaries.

## Overview

Trebuche is a distributed actor framework that enables location-transparent RPC for Swift. Your actors work the same whether they're local or remote – Trebuche handles the networking transparently.

## Creating Your First Distributed Actor

Use the `@Trebuchet` macro to mark an actor for distributed communication:

```swift
import Trebuche

@Trebuchet
distributed actor Counter {
    private var count = 0

    distributed func increment() -> Int {
        count += 1
        return count
    }

    distributed func get() -> Int {
        return count
    }
}
```

The `@Trebuchet` macro automatically adds `typealias ActorSystem = TrebuchetActorSystem` to your actor.

## Running a Server

Expose your actors on a server:

```swift
import Trebuche

let server = TrebuchetServer(transport: .webSocket(port: 8080))
let counter = Counter(actorSystem: server.actorSystem)
await server.expose(counter, as: "counter")

print("Server running on port 8080")
try await server.run()
```

## Connecting as a Client

Resolve and call remote actors:

```swift
import Trebuche

let client = TrebuchetClient(transport: .webSocket(host: "localhost", port: 8080))
try await client.connect()

let counter = try client.resolve(Counter.self, id: "counter")
let newValue = try await counter.increment()
print("Counter is now: \(newValue)")
```

## Using with SwiftUI

Trebuche provides SwiftUI integration for reactive actor connections:

```swift
import SwiftUI
import Trebuche

@main
struct MyApp: App {
    var body: some Scene {
        WindowGroup {
            ContentView()
                .trebuche(transport: .webSocket(host: "api.example.com", port: 8080))
        }
    }
}

struct CounterView: View {
    @RemoteActor(id: "counter") var counter: Counter?

    var body: some View {
        switch $counter.state {
        case .loading:
            ProgressView()
        case .resolved(let counter):
            CounterContent(counter: counter)
        case .failed(let error):
            Text("Error: \(error.localizedDescription)")
        case .disconnected:
            Text("Disconnected")
        }
    }
}
```

## Next Steps

- Learn about <doc:DefiningActors> for best practices
- Explore cloud deployment with ``TrebucheCloud`` and ``TrebucheAWS``
- Use the `trebuche` CLI for serverless deployment
