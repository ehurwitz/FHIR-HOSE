//
//  KTCDemoView.swift
//  FHIR-HOSE
//
//  Created by Claude Code on 1/27/26.
//

import SwiftUI
import OSLog

struct KTCDemoView: View {
    @StateObject private var vm = KTCDemo()
    private let logger = Logger(subsystem: "com.fhirhose.app", category: "KTCDemoView")

    var body: some View {
        Group {
            switch vm.phase {
            case .landing:
                landingView
            case .scanning:
                Text("Scanner UI coming next milestone.")
                    .foregroundColor(.secondary)
            case .analyzing:
                ProgressView("Analyzing scan...")
            case .editing:
                Text("Editing UI coming in a later milestone.")
                    .foregroundColor(.secondary)
            case .error(let message):
                errorView(message)
            }
        }
        .navigationTitle("KTC Demo")
        .navigationBarTitleDisplayMode(.inline)
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

            Button("Start Scan") {
                logger.info("User tapped Start Scan")
                vm.phase = .scanning
            }
            .buttonStyle(.borderedProminent)
            .tint(.indigo)
            .controlSize(.large)
        }
        .padding()
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
