# Security

Securing the OTel collector for production use.

## Overview

TrebuchetOTel includes built-in security features to protect your telemetry data from unauthorized access and abuse.

## Authentication

When an `authToken` is provided, the collector enforces authentication on all endpoints except `/health`:

```swift
Collector(port: 4318, authToken: "my-secret-token")
```

### OTLP Ingestion (Bearer Token)

OTLP endpoints (`/v1/traces`, `/v1/logs`, `/v1/metrics`) require a `Bearer` token:

```bash
curl -X POST http://localhost:4318/v1/traces \
  -H "Authorization: Bearer my-secret-token" \
  -H "Content-Type: application/json" \
  -d @traces.json
```

Bearer token verification uses **constant-time SHA-256 hash comparison** to prevent timing attacks. The token is hashed at server startup and never compared directly.

### Dashboard (Session Cookie)

The web dashboard uses session-based authentication:

1. Navigate to `/` — redirects to `/login` if not authenticated
2. Enter the auth token on the login form
3. A session cookie (`otel_session`) is set with `HttpOnly` and `SameSite=Strict` flags
4. Subsequent requests use the cookie (30-day expiry)

Login also uses constant-time hash comparison for the submitted token.

## Request Limits

### Body Size

Requests larger than **10 MB** are rejected with HTTP 413:

```
HTTP/1.1 413 Payload Too Large
```

This prevents memory exhaustion from oversized payloads.

### Content Type

Only OTLP/HTTP **JSON** encoding is supported. Protobuf payloads are rejected with HTTP 415 and a clear message:

```
HTTP/1.1 415 Unsupported Media Type
{"error": "Protobuf encoding is not supported. Configure your OTLP exporter to use JSON (OTEL_EXPORTER_OTLP_PROTOCOL=http/json)."}
```

### Compression

Gzip and deflate compressed payloads are currently rejected with HTTP 400. Configure your exporter to send uncompressed JSON:

```bash
export OTEL_EXPORTER_OTLP_COMPRESSION=none
```

## CORS

Cross-Origin Resource Sharing is configurable via the `corsOrigin` parameter:

```swift
Collector(port: 4318, corsOrigin: "https://my-dashboard.example.com")
```

The default is `*` (allow all origins), suitable for development. For production, restrict to your dashboard's origin.

The collector handles CORS preflight (`OPTIONS`) requests with:

- `Access-Control-Allow-Origin`: The configured origin
- `Access-Control-Allow-Methods`: `GET, POST, OPTIONS`
- `Access-Control-Allow-Headers`: `Content-Type, Authorization`

## Error Sanitization

Error responses from ingestion endpoints return generic messages (`"Invalid payload"`) instead of raw error details. This prevents information disclosure through stack traces or internal file paths.

## Best Practices

### Development

```swift
// Open access for local development
Collector(port: 4318)
```

### Production

```swift
// Restricted access with auth and CORS
Collector(
    port: 4318,
    authToken: ProcessInfo.processInfo.environment["OTEL_AUTH_TOKEN"]!,
    corsOrigin: "https://dashboard.example.com"
)
```

### Token Management

- Use environment variables for auth tokens — never hardcode in source
- Rotate tokens periodically
- Use different tokens for different environments
