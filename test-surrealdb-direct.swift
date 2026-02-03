#!/usr/bin/env swift
import Foundation

#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

// Test 1: Check health endpoint
print("Testing SurrealDB health endpoint...")
let healthURL = URL(string: "http://localhost:8000/health")!
var healthRequest = URLRequest(url: healthURL)
healthRequest.timeoutInterval = 5.0

let semaphore = DispatchSemaphore(value: 0)
var healthSuccess = false

URLSession.shared.dataTask(with: healthRequest) { data, response, error in
    if let error = error {
        print("❌ Health check failed: \(error)")
    } else if let httpResponse = response as? HTTPURLResponse {
        print("✓ Health check returned status: \(httpResponse.statusCode)")
        healthSuccess = httpResponse.statusCode == 200
    }
    semaphore.signal()
}.resume()

_ = semaphore.wait(timeout: .now() + 10)

if !healthSuccess {
    print("❌ SurrealDB is not responding properly")
    exit(1)
}

print("\n✓ SurrealDB is running and responding!")
print("Health endpoint: http://localhost:8000/health")
print("WebSocket endpoint: ws://localhost:8000/rpc")
