//
//  TrebucheDemoApp.swift
//  TrebucheDemo
//
//  Created by Brianna Zamora on 1/20/26.
//

import SwiftUI
import Trebuche

@main
struct TrebucheDemoApp: App {
    var body: some Scene {
        WindowGroup {
            ContentView()
                .trebuche(transport: .webSocket(host: "127.0.0.1", port: 8080))
        }
    }
}
