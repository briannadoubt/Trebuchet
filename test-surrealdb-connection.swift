#!/usr/bin/env swift

import Foundation

#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

func checkSurrealDB() async -> Bool {
    guard let url = URL(string: "http://localhost:8000/health") else {
        print("❌ Invalid URL")
        return false
    }

    var request = URLRequest(url: url)
    request.timeoutInterval = 5.0

    do {
        let (data, response) = try await URLSession.shared.data(for: request)

        guard let httpResponse = response as? HTTPURLResponse else {
            print("❌ Not an HTTP response")
            return false
        }

        print("✅ HTTP Status: \(httpResponse.statusCode)")
        print("✅ Response: \(String(data: data, encoding: .utf8) ?? "no data")")

        return httpResponse.statusCode == 200
    } catch {
        print("❌ Error: \(error)")
        return false
    }
}

print("Checking SurrealDB availability...")
let available = await checkSurrealDB()
print(available ? "✅ SurrealDB is available" : "❌ SurrealDB is NOT available")
exit(available ? 0 : 1)
