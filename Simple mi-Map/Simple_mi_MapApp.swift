//
//  Simple_mi_MapApp.swift
//  Simple mi-Map
//
//  Created by Yumi Ishiguro on 2025/08/25.
//

import SwiftUI
import CoreData

@main
struct Simple_mi_MapApp: App {
    let persistenceController = PersistenceController.shared

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environment(\.managedObjectContext, persistenceController.container.viewContext)
        }
    }
}
