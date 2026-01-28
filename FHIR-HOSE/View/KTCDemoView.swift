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
    @State private var showImageExpanded = false
    @State private var showLabelBoxes = true
    @State private var showCopiedToast = false
    @State private var showShareSheet = false
    @State private var exportPDFURL: URL?
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
        .sheet(isPresented: $showImageExpanded) {
            if let firstPage = vm.pages.first {
                KTCExpandedImageView(
                    image: firstPage,
                    fields: vm.fields,
                    showLabelBoxes: $showLabelBoxes
                )
            }
        }
        .sheet(isPresented: $showShareSheet) {
            if let url = exportPDFURL {
                KTCShareSheet(items: [url])
            }
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

    // MARK: - Editing (full interactive UI)

    private var editingView: some View {
        ScrollView {
            VStack(spacing: 16) {
                // Tappable image with overlay
                if let firstPage = vm.pages.first {
                    KTCOverlayView(
                        image: firstPage,
                        fields: vm.fields,
                        showLabelBoxes: showLabelBoxes
                    )
                    .frame(height: 220)
                    .cornerRadius(8)
                    .shadow(radius: 2)
                    .onTapGesture {
                        showImageExpanded = true
                    }
                    .overlay(alignment: .bottomTrailing) {
                        Image(systemName: "arrow.up.left.and.arrow.down.right")
                            .font(.caption)
                            .padding(6)
                            .background(.ultraThinMaterial)
                            .cornerRadius(6)
                            .padding(8)
                    }
                }

                // Controls row
                HStack {
                    Toggle("Boxes", isOn: $showLabelBoxes)
                        .toggleStyle(.switch)
                        .labelsHidden()
                    Text("Label boxes")
                        .font(.caption)
                        .foregroundColor(.secondary)

                    Spacer()

                    let matched = vm.fields.filter { $0.mappedKeypath != nil }.count
                    let detected = vm.fields.filter { $0.detectedValue != nil }.count
                    Label("\(vm.recognizedLines.count) lines", systemImage: "text.alignleft")
                    Spacer()
                    Label("\(vm.fields.count) fields", systemImage: "tag")
                    Spacer()
                    Label("\(detected) detected", systemImage: "doc.text.magnifyingglass")
                        .foregroundColor(detected > 0 ? .orange : .secondary)
                    Spacer()
                    Label("\(matched) matched", systemImage: "checkmark.circle")
                        .foregroundColor(matched > 0 ? .green : .secondary)
                }
                .font(.caption)
                .foregroundColor(.secondary)

                Divider()

                // Checkbox Groups Section
                if !vm.checkboxGroups.isEmpty {
                    VStack(alignment: .leading, spacing: 8) {
                        HStack {
                            Image(systemName: "checkmark.square")
                                .foregroundColor(.indigo)
                            Text("Checkbox Groups")
                                .font(.headline)
                            Spacer()
                            let autoChecked = vm.checkboxGroups.filter { $0.selectedIndex != nil }.count
                            Text("\(autoChecked)/\(vm.checkboxGroups.count) auto-filled")
                                .font(.caption)
                                .foregroundColor(.secondary)
                        }

                        ForEach(vm.checkboxGroups.indices, id: \.self) { groupIdx in
                            let group = vm.checkboxGroups[groupIdx]
                            // Only show groups with 2+ options (actual choice groups)
                            if group.options.count > 1 {
                                VStack(alignment: .leading, spacing: 6) {
                                    // Group label
                                    HStack {
                                        if let label = group.groupLabel {
                                            Text(label)
                                                .font(.subheadline)
                                                .fontWeight(.medium)
                                        } else {
                                            Text("Choice")
                                                .font(.subheadline)
                                                .foregroundColor(.secondary)
                                        }
                                        if let keypath = group.mappedKeypath {
                                            Text("→ \(vm.displayName(for: keypath))")
                                                .font(.caption)
                                                .foregroundColor(.indigo)
                                        }
                                        Spacer()
                                        if group.selectedIndex != nil {
                                            Image(systemName: "checkmark.circle.fill")
                                                .foregroundColor(.green)
                                                .font(.caption)
                                        }
                                    }

                                    // Checkbox options
                                    HStack(spacing: 16) {
                                        ForEach(group.options.indices, id: \.self) { optIdx in
                                            let option = group.options[optIdx]
                                            Button {
                                                // Toggle this checkbox
                                                vm.toggleCheckbox(groupIndex: groupIdx, optionIndex: optIdx)
                                            } label: {
                                                HStack(spacing: 4) {
                                                    Image(systemName: option.isChecked ? "checkmark.square.fill" : "square")
                                                        .foregroundColor(option.isChecked ? .indigo : .gray)
                                                    Text(option.associatedText ?? "Option \(optIdx + 1)")
                                                        .font(.subheadline)
                                                        .foregroundColor(option.isChecked ? .primary : .secondary)
                                                }
                                            }
                                            .buttonStyle(.plain)
                                        }
                                    }
                                }
                                .padding(10)
                                .background(Color(.systemGray6))
                                .cornerRadius(8)
                            }
                        }
                    }
                    .padding(.vertical, 4)

                    Divider()
                }

                // Field list
                if vm.fields.isEmpty && vm.checkboxGroups.isEmpty {
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
                } else if !vm.fields.isEmpty {
                    // Text Fields Header
                    HStack {
                        Image(systemName: "text.cursor")
                            .foregroundColor(.indigo)
                        Text("Text Fields")
                            .font(.headline)
                        Spacer()
                        let matched = vm.fields.filter { $0.mappedKeypath != nil }.count
                        Text("\(matched)/\(vm.fields.count) mapped")
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
                    .padding(.top, 4)

                    ForEach($vm.fields) { $field in
                        VStack(alignment: .leading, spacing: 8) {
                            // Label (from OCR)
                            HStack {
                                Text(field.label)
                                    .font(.headline)
                                Spacer()
                                if field.detectedValue != nil {
                                    Image(systemName: "doc.text.magnifyingglass")
                                        .font(.caption)
                                        .foregroundColor(.green)
                                }
                            }

                            // Show detected value from form (if any)
                            if let detected = field.detectedValue, !detected.isEmpty {
                                HStack {
                                    Text("On form:")
                                        .font(.caption)
                                        .foregroundColor(.secondary)
                                    Text(detected)
                                        .font(.caption)
                                        .foregroundColor(.green)
                                        .lineLimit(1)
                                }
                            }

                            // Keypath picker with confidence indicator
                            HStack {
                                Text("Map to:")
                                    .font(.caption)
                                    .foregroundColor(.secondary)
                                Picker("Keypath", selection: Binding<String>(
                                    get: { field.mappedKeypath ?? "__none__" },
                                    set: { newVal in
                                        let kp = newVal == "__none__" ? nil : newVal
                                        vm.updateFieldKeypath(id: field.id, newKeypath: kp)
                                    }
                                )) {
                                    Text("None").tag("__none__")
                                    ForEach(vm.sortedKeypaths, id: \.self) { kp in
                                        Text(vm.displayName(for: kp)).tag(kp)
                                    }
                                }
                                .pickerStyle(.menu)
                                .tint(.indigo)

                                // Confidence badge
                                if field.mappedKeypath != nil && field.matchConfidence > 0 {
                                    Text("\(Int(field.matchConfidence * 100))%")
                                        .font(.caption2)
                                        .fontWeight(.medium)
                                        .foregroundColor(.white)
                                        .padding(.horizontal, 6)
                                        .padding(.vertical, 2)
                                        .background(confidenceColor(field.matchConfidence))
                                        .cornerRadius(8)
                                }
                            }

                            // Value text field
                            HStack {
                                TextField("Value", text: $field.value)
                                    .textFieldStyle(.roundedBorder)

                                if field.mappedKeypath != nil {
                                    Button {
                                        vm.resetField(id: field.id)
                                    } label: {
                                        Image(systemName: "arrow.counterclockwise")
                                            .font(.caption)
                                    }
                                    .buttonStyle(.bordered)
                                    .tint(.indigo)
                                    .help("Reset from JSON")
                                }
                            }
                        }
                        .padding(12)
                        .background(Color(.systemGray6))
                        .cornerRadius(10)
                    }
                }

                Divider()

                // Export actions
                VStack(spacing: 12) {
                    Button {
                        vm.copyToClipboard()
                        showCopiedToast = true
                        DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
                            showCopiedToast = false
                        }
                    } label: {
                        Label("Copy Filled Data", systemImage: "doc.on.clipboard")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(.indigo)
                    .controlSize(.large)

                    Button {
                        if let url = vm.generateFilledPDF() {
                            exportPDFURL = url
                            showShareSheet = true
                        }
                    } label: {
                        Label("Export Filled PDF", systemImage: "square.and.arrow.up")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.bordered)
                    .tint(.indigo)
                    .controlSize(.large)
                }

                Divider()

                Button("Start Over") {
                    vm.phase = .landing
                    vm.pages = []
                    vm.recognizedLines = []
                    vm.fields = []
                    vm.checkboxGroups = []
                }
                .buttonStyle(.bordered)
                .tint(.red)
            }
            .padding()
        }
        .overlay {
            if showCopiedToast {
                VStack {
                    Spacer()
                    Text("Copied to clipboard!")
                        .font(.subheadline)
                        .fontWeight(.medium)
                        .foregroundColor(.white)
                        .padding(.horizontal, 16)
                        .padding(.vertical, 10)
                        .background(Color.indigo)
                        .cornerRadius(20)
                        .shadow(radius: 4)
                        .padding(.bottom, 30)
                }
                .transition(.move(edge: .bottom).combined(with: .opacity))
                .animation(.easeInOut, value: showCopiedToast)
            }
        }
    }

    // MARK: - Helpers

    private func confidenceColor(_ confidence: Double) -> Color {
        if confidence >= 0.9 { return .green }
        if confidence >= 0.7 { return .blue }
        if confidence >= 0.5 { return .orange }
        return .red
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
