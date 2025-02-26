//
//  SettingsView.swift
//  FHIR-HOSE
//
//  Created by Eric Hurwitz on 12/3/24.
//

import SwiftUI

struct SettingsView: View {
    @State private var autoProcessing = true
    @State private var storageLimit = 1.0
    
    var body: some View {
        Form {
            Section(header: Text("Processing")) {
                Toggle("Auto-process new records", isOn: $autoProcessing)
            }
            
            Section(header: Text("Storage")) {
                HStack {
                    Text("Storage Limit")
                    Spacer()
                    Text("\(Int(storageLimit))GB")
                }
                Slider(value: $storageLimit, in: 1...10, step: 1)
            }
            
            Section(header: Text("Privacy")) {
                NavigationLink("Privacy Settings") {
                    Text("Privacy Settings")
                }
                NavigationLink("Data Sharing") {
                    Text("Data Sharing")
                }
            }
        }
    }
}

