//
//  TrebuchetDemoApp.swift
//  TrebuchetDemo
//
//  Created by Brianna Zamora on 1/20/26.
//

import SwiftUI
import Trebuchet

@main
struct TrebuchetDemoApp: App {
    var body: some Scene {
        WindowGroup {
            ContentView()
                .Trebuchet(transport: .webSocket(host: "127.0.0.1", port: 8080))
        }
    }
}
