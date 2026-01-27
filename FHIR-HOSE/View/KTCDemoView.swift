//
//  KTCDemoView.swift
//  FHIR-HOSE
//
//  Created by Claude Code on 1/27/26.
//

import SwiftUI
import VisionKit
import OSLog

struct KTCDemoView: View {
    @StateObject private var vm = KTCDemo()
    @State private var showScanner = false
    @State private var showPhotoPicker = false
    private let logger = Logger(subsystem: "com.fhirhose.app", category: "KTCDemoView")

    var body: some View {
        Group {
            switch vm.phase {
            case .landing:
                landingView
            case .scanning:
                scanningView
            case .analyzing:
                analyzingView
            case .editing:
                editingView
            case .error(let message):
                errorView(message)
            }
        }
        .navigationTitle("KTC Demo")
        .navigationBarTitleDisplayMode(.inline)
        .fullScreenCover(isPresented: $showScanner) {
            KTCDocumentScanner(
                onScan: { images in
                    vm.handleScannedPages(images)
                },
                onCancel: {
                    vm.cancelScan()
                }
            )
            .ignoresSafeArea()
        }
        .sheet(isPresented: $showPhotoPicker) {
            KTCPhotoPicker(
                onPick: { image in
                    vm.handlePickedPhoto(image)
                },
                onCancel: {
                    vm.cancelScan()
                }
            )
        }
    }

    // MARK: - Landing

    private var landingView: some View {
        VStack(spacing: 30) {
            VStack(spacing: 15) {
                Image(systemName: "doc.text.viewfinder")
                    .font(.system(size: 60))
                    .foregroundColor(.indigo)

                Text("Kill-The-Clipboard")
                    .font(.largeTitle)
                    .fontWeight(.bold)
                    .multilineTextAlignment(.center)

                Text("Scan a paper medical form, auto-fill it with patient data, and export the result.")
                    .font(.subheadline)
                    .foregroundColor(.secondary)
                    .multilineTextAlignment(.center)
            }

            VStack(alignment: .leading, spacing: 8) {
                Label("Scan or photograph a paper form", systemImage: "camera.viewfinder")
                Label("OCR detects field labels automatically", systemImage: "text.viewfinder")
                Label("Patient data is fuzzy-matched to fields", systemImage: "person.text.rectangle")
                Label("Review, edit, and export the result", systemImage: "pencil.and.list.clipboard")
            }
            .font(.subheadline)
            .padding()
            .background(Color(.systemGray6))
            .cornerRadius(12)

            VStack(spacing: 12) {
                if VNDocumentCameraViewController.isSupported {
                    Button {
                        logger.info("User tapped Scan Document")
                        vm.phase = .scanning
                        showScanner = true
                    } label: {
                        Label("Scan Document", systemImage: "doc.viewfinder")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(.indigo)
                    .controlSize(.large)
                }

                Button {
                    logger.info("User tapped Pick Photo")
                    vm.phase = .scanning
                    showPhotoPicker = true
                } label: {
                    Label("Pick from Photos", systemImage: "photo.on.rectangle")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.bordered)
                .tint(.indigo)
                .controlSize(.large)
            }
        }
        .padding()
    }

    // MARK: - Scanning

    private var scanningView: some View {
        VStack(spacing: 20) {
            ProgressView()
                .scaleEffect(1.5)
            Text("Waiting for scan...")
                .font(.headline)
                .foregroundColor(.secondary)

            Button("Cancel") {
                vm.cancelScan()
            }
            .buttonStyle(.bordered)
        }
        .padding()
    }

    // MARK: - Analyzing

    private var analyzingView: some View {
        VStack(spacing: 20) {
            if let firstPage = vm.pages.first {
                Image(uiImage: firstPage)
                    .resizable()
                    .scaledToFit()
                    .frame(maxHeight: 400)
                    .cornerRadius(12)
                    .shadow(radius: 4)
            }

            ProgressView("Analyzing scan...")
                .font(.headline)

            Text("OCR processing coming next milestone.")
                .font(.caption)
                .foregroundColor(.secondary)
        }
        .padding()
    }

    // MARK: - Editing (field list)

    private var editingView: some View {
        ScrollView {
            VStack(spacing: 16) {
                // Scanned image thumbnail
                if let firstPage = vm.pages.first {
                    Image(uiImage: firstPage)
                        .resizable()
                        .scaledToFit()
                        .frame(maxHeight: 200)
                        .cornerRadius(8)
                        .shadow(radius: 2)
                }

                // Stats
                HStack {
                    Label("\(vm.recognizedLines.count) OCR lines", systemImage: "text.alignleft")
                    Spacer()
                    Label("\(vm.fields.count) fields detected", systemImage: "tag")
                }
                .font(.caption)
                .foregroundColor(.secondary)

                Divider()

                if vm.fields.isEmpty {
                    VStack(spacing: 12) {
                        Image(systemName: "doc.text.magnifyingglass")
                            .font(.largeTitle)
                            .foregroundColor(.secondary)
                        Text("No field labels detected.")
                            .font(.headline)
                        Text("Try scanning a form with clear labels like \"Name:\", \"DOB:\", etc.")
                            .font(.subheadline)
                            .foregroundColor(.secondary)
                            .multilineTextAlignment(.center)
                    }
                    .padding(.vertical, 30)
                } else {
                    ForEach(vm.fields) { field in
                        HStack {
                            VStack(alignment: .leading, spacing: 4) {
                                Text(field.label)
                                    .font(.headline)
                                if let keypath = field.mappedKeypath {
                                    Text(keypath)
                                        .font(.caption)
                                        .foregroundColor(.indigo)
                                } else {
                                    Text("No mapping yet")
                                        .font(.caption)
                                        .foregroundColor(.secondary)
                                }
                            }
                            Spacer()
                            Text(field.value.isEmpty ? "—" : field.value)
                                .foregroundColor(field.value.isEmpty ? .secondary : .primary)
                        }
                        .padding(.vertical, 6)
                    }
                }

                Divider()

                Button("Start Over") {
                    vm.phase = .landing
                    vm.pages = []
                    vm.recognizedLines = []
                    vm.fields = []
                }
                .buttonStyle(.bordered)
                .tint(.indigo)
            }
            .padding()
        }
    }

    // MARK: - Error

    private func errorView(_ message: String) -> some View {
        VStack(spacing: 20) {
            Image(systemName: "exclamationmark.triangle")
                .font(.largeTitle)
                .foregroundColor(.orange)

            Text("Something went wrong")
                .font(.headline)

            Text(message)
                .font(.subheadline)
                .foregroundColor(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal)

            Button("Back to Start") {
                vm.phase = .landing
            }
            .buttonStyle(.borderedProminent)
        }
        .padding()
    }
}

#Preview {
    NavigationView {
        KTCDemoView()
    }
}
