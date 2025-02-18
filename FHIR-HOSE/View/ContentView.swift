//
//  ContentView.swift
//  FHIR-HOSE
//
//  Created by Eric Hurwitz on 12/3/24.
//

import SwiftUI
import UniformTypeIdentifiers


struct ContentView: View {
    @StateObject private var recordStore = HealthRecordStore()
    @State private var showingDocumentPicker = false
    @State private var showingImagePicker = false
    @State private var selectedTab = 0
    @State private var healthDataMessage = "Press the button to fetch HealthKit data."
        private let healthKitManager = HealthKitManager()
    
    var body: some View {
        TabView(selection: $selectedTab) {
            
            // Records Tab
            NavigationView {
                
                // TODO: REMOVE THIS - right now this blocks some function but is here to show healthkit capability
                Button(action: fetchHealthData) {
                                Text("Fetch Now")
                                    .font(.headline)
                                    .padding()
                                    .frame(maxWidth: .infinity)
                                    .background(Color.green)
                                    .foregroundColor(.white)
                                    .cornerRadius(10)
                            }
                
                RecordsListView(recordStore: recordStore)
                    .navigationTitle("Health Records")
                    .toolbar {
                        ToolbarItem(placement: .primaryAction) {
                            Menu {
                                Button(action: { showingDocumentPicker = true }) {
                                    Label("Upload Document", systemImage: "doc")
                                }
                                Button(action: { showingImagePicker = true }) {
                                    Label("Upload Image", systemImage: "photo")
                                }
                            } label: {
                                Image(systemName: "plus")
                            }
                        }
                    }
            }
            .tabItem {
                Label("Records", systemImage: "list.bullet")
            }
            .tag(0)
            
            // Settings Tab
            NavigationView {
                SettingsView()
                    .navigationTitle("Settings")
            }
            .tabItem {
                Label("Settings", systemImage: "gear")
            }
            .tag(1)
        }
        .sheet(isPresented: $showingDocumentPicker) {
            DocumentPicker(recordStore: recordStore)
        }
        .sheet(isPresented: $showingImagePicker) {
            ImagePicker(recordStore: recordStore)
        }
    }
    
    private func fetchHealthData() {
            healthKitManager.requestAuthorization { success, error in
                if success {
                    if let result = healthKitManager.fetchNameAndBirthday() {
                        DispatchQueue.main.async {
                            if let birthday = result.birthday {
                                healthDataMessage = """
                                User's Name: \(result.name ?? "Unknown")
                                User's Birthday: \(birthday)
                                """
                                print(healthDataMessage)
                            } else {
                                healthDataMessage = "Could not retrieve birthday."
                                print(healthDataMessage)
                            }
                        }
                    }
                } else {
                    DispatchQueue.main.async {
                        healthDataMessage = "HealthKit authorization failed: \(error?.localizedDescription ?? "Unknown error")"
                        print(healthDataMessage)
                    }
                }
            }
        }
}



