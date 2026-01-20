# Deploying to Google Cloud Platform

Deploy your distributed actors to Google Cloud Functions with Firestore and Service Directory.

## Overview

> Note: GCP support is planned for a future release. This document describes the intended architecture.

Trebuche will support deployment to Google Cloud Platform using:
- **Cloud Functions** (Gen 2) for actor execution
- **Firestore** for actor state persistence
- **Service Directory** for actor discovery

## Planned Architecture

```
┌─────────────────────────────────────────────────────────────────┐
│                    Google Cloud Platform                         │
│  ┌─────────────────────────────────────────────────────────┐   │
│  │           Cloud Functions (Gen 2)                        │   │
│  │  ┌─────────────┐    ┌─────────────┐    ┌────────────┐  │   │
│  │  │ UserService │    │  GameRoom   │    │   Lobby    │  │   │
│  │  └─────────────┘    └─────────────┘    └────────────┘  │   │
│  └─────────────────────────────────────────────────────────┘   │
│                              ↓                                  │
│  ┌──────────────┐  ┌──────────────────┐  ┌────────────────┐   │
│  │  Firestore   │  │ Service Directory │  │  Cloud Run     │   │
│  │ (actor state)│  │   (discovery)     │  │  (endpoint)    │   │
│  └──────────────┘  └──────────────────┘  └────────────────┘   │
└─────────────────────────────────────────────────────────────────┘
```

## Planned Configuration

```yaml
name: my-game-server
version: "1"

defaults:
  provider: gcp
  region: us-central1
  memory: 512
  timeout: 30

actors:
  GameRoom:
    memory: 1024
    stateful: true

state:
  type: firestore
  collection: actor-state

discovery:
  type: service-directory
  namespace: my-game
```

## Planned Usage

```bash
# Deploy to GCP
trebuche deploy --provider gcp --region us-central1

# Expected output
Discovering actors...
  ✓ GameRoom
  ✓ Lobby

Building for Cloud Functions...
  ✓ Package built

Deploying to GCP...
  ✓ Cloud Function: projects/my-project/locations/us-central1/functions/my-game-actors
  ✓ Cloud Run URL: https://my-game-actors-abc123-uc.a.run.app
  ✓ Firestore: actor-state collection
  ✓ Service Directory: my-game namespace

Ready!
```

## GCP-Specific Components

### FirestoreStateStore (Planned)

```swift
// Future implementation
let stateStore = FirestoreStateStore(
    projectId: "my-project",
    collection: "actor-state"
)
```

### ServiceDirectoryRegistry (Planned)

```swift
// Future implementation
let registry = ServiceDirectoryRegistry(
    projectId: "my-project",
    location: "us-central1",
    namespace: "my-game"
)
```

### CloudFunctionTransport (Planned)

```swift
// Future implementation
let transport = CloudFunctionTransport(
    functionUrl: "https://my-function-abc123-uc.a.run.app"
)
```

## Authentication

GCP authentication will use Application Default Credentials (ADC):

```bash
# Local development
gcloud auth application-default login

# Service account
export GOOGLE_APPLICATION_CREDENTIALS=/path/to/service-account.json
```

## Cost Considerations

Cloud Functions pricing:
- **Invocations**: $0.40 per million
- **Compute**: $0.000024 per GB-second

Firestore pricing:
- **Document reads**: $0.06 per 100K
- **Document writes**: $0.18 per 100K

## Contributing

GCP support contributions are welcome! See the TrebucheCloud protocols:
- ``CloudProvider``
- ``ActorStateStore``
- ``ServiceRegistry``

## See Also

- <doc:CloudDeploymentOverview>
- <doc:DeployingToAWS>
- <doc:DeployingToAzure>
