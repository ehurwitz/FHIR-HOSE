//
//  KTCDemo.swift
//  FHIR-HOSE
//
//  Created by Claude Code on 1/27/26.
//

import Foundation
import OSLog
import UIKit
import Vision

// MARK: - Data Structures

struct KTCRecognizedLine: Identifiable {
    let id = UUID()
    let text: String
    let boundingBox: CGRect   // Vision normalized coords (origin bottom-left)
    let confidence: Float
    let pageIndex: Int
}

struct KTCField: Identifiable {
    let id = UUID()
    var label: String
    var labelBoundingBox: CGRect
    var mappedKeypath: String?
    var value: String = ""
}

// MARK: - ViewModel

@MainActor
final class KTCDemo: ObservableObject {
    private let logger = Logger(subsystem: "com.fhirhose.app", category: "KTC")

    enum Phase {
        case landing
        case scanning
        case analyzing
        case editing
        case error(String)
    }

    @Published var phase: Phase = .landing
    @Published var pages: [UIImage] = []
    @Published var recognizedLines: [KTCRecognizedLine] = []
    @Published var fields: [KTCField] = []
    @Published var patientData: [String: String] = [:]  // flattened keypath → value

    /// Sorted keypath list for Picker UI.
    var sortedKeypaths: [String] {
        patientData.keys.sorted()
    }

    // MARK: - Field editing

    func updateFieldKeypath(id: UUID, newKeypath: String?) {
        guard let idx = fields.firstIndex(where: { $0.id == id }) else { return }
        fields[idx].mappedKeypath = newKeypath
        if let kp = newKeypath, let val = patientData[kp] {
            fields[idx].value = val
        } else {
            fields[idx].value = ""
        }
    }

    func resetField(id: UUID) {
        guard let idx = fields.firstIndex(where: { $0.id == id }) else { return }
        if let kp = fields[idx].mappedKeypath, let val = patientData[kp] {
            fields[idx].value = val
        }
    }

    // MARK: - Scan / Pick handlers

    func handleScannedPages(_ images: [UIImage]) {
        guard !images.isEmpty else {
            logger.warning("Scanner returned zero pages")
            phase = .landing
            return
        }
        logger.info("Received \(images.count) scanned page(s)")
        pages = images
        phase = .analyzing
        runOCR()
    }

    func handlePickedPhoto(_ image: UIImage) {
        logger.info("Received picked photo")
        pages = [image]
        phase = .analyzing
        runOCR()
    }

    func cancelScan() {
        logger.info("Scan/pick cancelled")
        phase = .landing
    }

    // MARK: - OCR + Mapping Pipeline

    private func runOCR() {
        guard let image = pages.first, let cgImage = image.cgImage else {
            phase = .error("Could not read the scanned image.")
            return
        }
        logger.info("Starting OCR on first page (\(cgImage.width)x\(cgImage.height))")

        Task.detached(priority: .userInitiated) { [weak self] in
            guard let self else { return }
            do {
                // 1. OCR
                let lines = try await Self.performOCR(on: cgImage, pageIndex: 0)
                // 2. Extract label candidates
                var detectedFields = Self.extractLabelCandidates(from: lines)
                // 3. Load + flatten patient JSON
                let data = KTCPatientDataLoader.loadAndFlatten()
                // 4. Fuzzy-match labels → keypaths and fill values
                KTCPatientDataLoader.applyMappings(to: &detectedFields, using: data)

                await MainActor.run {
                    self.recognizedLines = lines
                    self.fields = detectedFields
                    self.patientData = data
                    self.logger.info("OCR complete: \(lines.count) lines, \(detectedFields.count) fields, \(data.count) patient keypaths")
                    self.phase = .editing
                }
            } catch {
                await MainActor.run {
                    self.logger.error("OCR failed: \(error.localizedDescription)")
                    self.phase = .error("OCR failed: \(error.localizedDescription)")
                }
            }
        }
    }

    /// Run VNRecognizeTextRequest and return recognized lines.
    private nonisolated static func performOCR(on cgImage: CGImage, pageIndex: Int) async throws -> [KTCRecognizedLine] {
        try await withCheckedThrowingContinuation { continuation in
            let request = VNRecognizeTextRequest { request, error in
                if let error {
                    continuation.resume(throwing: error)
                    return
                }
                guard let observations = request.results as? [VNRecognizedTextObservation] else {
                    continuation.resume(returning: [])
                    return
                }

                let lines: [KTCRecognizedLine] = observations.compactMap { obs in
                    guard let candidate = obs.topCandidates(1).first else { return nil }
                    return KTCRecognizedLine(
                        text: candidate.string,
                        boundingBox: obs.boundingBox,
                        confidence: candidate.confidence,
                        pageIndex: pageIndex
                    )
                }
                continuation.resume(returning: lines)
            }
            request.recognitionLevel = .accurate
            request.usesLanguageCorrection = true

            let handler = VNImageRequestHandler(cgImage: cgImage, options: [:])
            do {
                try handler.perform([request])
            } catch {
                continuation.resume(throwing: error)
            }
        }
    }

    // MARK: - Label Detection Heuristics

    /// Common label keywords found on medical forms.
    private static let labelKeywords: Set<String> = [
        "name", "first", "last", "middle", "patient",
        "dob", "date of birth", "birth date", "birthday",
        "sex", "gender",
        "phone", "telephone", "cell", "mobile", "fax",
        "email", "e-mail",
        "address", "street", "line", "apt", "suite",
        "city", "state", "zip", "postal", "zip code", "postal code",
        "ssn", "social security",
        "insurance", "payer", "plan", "carrier",
        "member", "member id", "subscriber", "group", "group id", "policy",
        "employer", "occupation",
        "emergency", "contact",
        "allergies", "medications", "pharmacy",
        "physician", "doctor", "provider", "referring",
        "signature", "date", "signed",
        "reason", "visit", "chief complaint",
        "height", "weight",
        "race", "ethnicity", "marital", "language",
        "guarantor", "responsible party",
    ]

    /// Extract field-label candidates from OCR lines using heuristics.
    nonisolated static func extractLabelCandidates(from lines: [KTCRecognizedLine]) -> [KTCField] {
        var fields: [KTCField] = []
        var seenLabels: Set<String> = []

        for line in lines {
            guard line.confidence > 0.3 else { continue }
            guard line.text.count <= 80 else { continue }

            let trimmed = line.text.trimmingCharacters(in: .whitespaces)
            guard !trimmed.isEmpty else { continue }

            // Strategy 1: Line contains a colon → text before colon is the label
            if let colonIdx = trimmed.firstIndex(of: ":") {
                let labelPart = String(trimmed[trimmed.startIndex..<colonIdx])
                    .trimmingCharacters(in: .whitespaces)
                if !labelPart.isEmpty && labelPart.count <= 50 {
                    let normalized = labelPart.lowercased()
                    if !seenLabels.contains(normalized) {
                        seenLabels.insert(normalized)
                        fields.append(KTCField(
                            label: labelPart,
                            labelBoundingBox: line.boundingBox
                        ))
                    }
                    continue
                }
            }

            // Strategy 2: Line matches a known keyword
            let lower = trimmed.lowercased()
            let matched = labelKeywords.contains { keyword in
                lower == keyword
                    || lower.hasPrefix(keyword + " ")
                    || lower.hasPrefix(keyword + "/")
                    || lower.hasPrefix(keyword + "(")
            }

            if matched {
                let normalized = lower
                if !seenLabels.contains(normalized) {
                    seenLabels.insert(normalized)
                    fields.append(KTCField(
                        label: trimmed,
                        labelBoundingBox: line.boundingBox
                    ))
                }
            }
        }

        return fields
    }
}

// MARK: - Patient Data Loader & Fuzzy Matcher

/// Handles loading the demo JSON, flattening it, and fuzzy-matching labels to keypaths.
enum KTCPatientDataLoader {
    private static let logger = Logger(subsystem: "com.fhirhose.app", category: "KTC-Mapper")

    // MARK: - Load & Flatten

    /// Load ktc-demo-patient.json from the bundle and flatten to [keypath: value].
    static func loadAndFlatten() -> [String: String] {
        guard let url = Bundle.main.url(forResource: "ktc-demo-patient", withExtension: "json") else {
            logger.error("ktc-demo-patient.json not found in bundle")
            return [:]
        }
        do {
            let data = try Data(contentsOf: url)
            guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                logger.error("JSON root is not a dictionary")
                return [:]
            }
            var flat: [String: String] = [:]
            flatten(json, prefix: "", into: &flat)

            // Computed: fullName
            if let first = flat["patient.firstName"], let last = flat["patient.lastName"] {
                flat["patient.fullName"] = "\(first) \(last)"
            }

            logger.info("Loaded \(flat.count) patient keypaths")
            return flat
        } catch {
            logger.error("Failed to load patient JSON: \(error.localizedDescription)")
            return [:]
        }
    }

    /// Recursively flatten a JSON dictionary into dot-separated keypaths.
    private static func flatten(_ obj: Any, prefix: String, into result: inout [String: String]) {
        if let dict = obj as? [String: Any] {
            for (key, value) in dict {
                let path = prefix.isEmpty ? key : "\(prefix).\(key)"
                flatten(value, prefix: path, into: &result)
            }
        } else if let array = obj as? [Any] {
            for (i, value) in array.enumerated() {
                flatten(value, prefix: "\(prefix)[\(i)]", into: &result)
            }
        } else {
            result[prefix] = "\(obj)"
        }
    }

    // MARK: - Synonym Map

    /// Maps normalized label text → canonical keypath tail.
    /// Multiple synonyms can point to the same keypath.
    private static let synonyms: [(patterns: [String], keypath: String)] = [
        // Name
        (["full name", "patient name", "participant name", "name of patient", "patient's name"], "patient.fullName"),
        (["first name", "first", "given name"], "patient.firstName"),
        (["last name", "last", "surname", "family name"], "patient.lastName"),
        // DOB
        (["dob", "date of birth", "birth date", "birthday", "birthdate", "d.o.b", "d.o.b."], "patient.dateOfBirth"),
        // Sex
        (["sex", "gender", "sex/gender", "sex / gender"], "patient.sex"),
        // Contact
        (["phone", "telephone", "cell", "mobile", "phone number", "tel", "cell phone", "home phone", "daytime phone"], "patient.phone"),
        (["email", "e-mail", "email address", "e-mail address"], "patient.email"),
        // Address
        (["address", "street", "street address", "address line 1", "address 1", "line 1", "mailing address", "home address"], "patient.address.line1"),
        (["address line 2", "address 2", "line 2", "apt", "suite", "unit", "apt/suite"], "patient.address.line2"),
        (["city", "city/town"], "patient.address.city"),
        (["state", "state/province"], "patient.address.state"),
        (["zip", "zip code", "zipcode", "postal code", "postal", "zip/postal"], "patient.address.postalCode"),
        // Insurance
        (["member id", "member #", "member no", "member number", "subscriber id", "subscriber", "id #", "id number", "identification number"], "patient.insurance.memberId"),
        (["group", "group id", "group #", "group no", "group number", "grp", "grp #"], "patient.insurance.groupId"),
        (["payer", "insurance", "insurance company", "plan", "carrier", "health plan", "insurance plan", "insurance name"], "patient.insurance.payer"),
    ]

    // MARK: - Fuzzy Match

    /// Try to match a label string to a keypath. Returns (keypath, value) or nil.
    static func fuzzyMatch(label: String, in data: [String: String]) -> (keypath: String, value: String)? {
        let normalized = normalize(label)

        // 1. Exact synonym match
        for entry in synonyms {
            for pattern in entry.patterns {
                if normalized == pattern {
                    if let value = data[entry.keypath] {
                        return (entry.keypath, value)
                    }
                }
            }
        }

        // 2. Whole-word substring match (label contains a synonym as complete words)
        for entry in synonyms {
            for pattern in entry.patterns {
                if pattern.count >= 3 && containsWholeWords(normalized, pattern: pattern) {
                    if let value = data[entry.keypath] {
                        return (entry.keypath, value)
                    }
                }
            }
        }

        // 3. Token overlap with keypath tails
        let labelTokens = tokenize(normalized)
        guard !labelTokens.isEmpty else { return nil }

        var bestScore: Double = 0
        var bestKeypath: String?

        for keypath in data.keys {
            // Extract the tail of the keypath (e.g., "patient.address.city" → "city")
            let tail = keypath.components(separatedBy: ".").last ?? keypath
            let keypathTokens = tokenize(camelCaseToWords(tail))

            guard !keypathTokens.isEmpty else { continue }

            // Jaccard-like overlap score
            let labelSet = Set(labelTokens)
            let keypathSet = Set(keypathTokens)
            let intersection = labelSet.intersection(keypathSet).count
            let union = labelSet.union(keypathSet).count
            let score = Double(intersection) / Double(union)

            if score > bestScore {
                bestScore = score
                bestKeypath = keypath
            }
        }

        // Require a minimum threshold
        if bestScore >= 0.5, let keypath = bestKeypath, let value = data[keypath] {
            return (keypath, value)
        }

        return nil
    }

    /// Apply fuzzy matching to all fields.
    static func applyMappings(to fields: inout [KTCField], using data: [String: String]) {
        for i in fields.indices {
            let label = fields[i].label
            if let match = fuzzyMatch(label: label, in: data) {
                fields[i].mappedKeypath = match.keypath
                fields[i].value = match.value
                logger.info("Mapped '\(label)' → \(match.keypath) = \(match.value)")
            } else {
                logger.info("No match for '\(label)'")
            }
        }
    }

    // MARK: - Text Helpers

    /// Normalize a label: lowercase, strip punctuation, collapse whitespace.
    private static func normalize(_ text: String) -> String {
        let lower = text.lowercased()
        let cleaned = lower.unicodeScalars.map { char -> Character in
            if CharacterSet.alphanumerics.contains(char) || char == " " {
                return Character(char)
            }
            return " "
        }
        return String(cleaned)
            .components(separatedBy: .whitespaces)
            .filter { !$0.isEmpty }
            .joined(separator: " ")
    }

    /// Tokenize a string into lowercase words.
    private static func tokenize(_ text: String) -> [String] {
        text.lowercased()
            .components(separatedBy: .whitespaces)
            .filter { !$0.isEmpty && $0.count > 1 }
    }

    /// Check if `pattern` appears in `text` at word boundaries.
    /// e.g. "city" is found in "my city name" but NOT in "ethnicity".
    private static func containsWholeWords(_ text: String, pattern: String) -> Bool {
        let padded = " \(text) "
        return padded.contains(" \(pattern) ")
    }

    /// Convert camelCase to space-separated words. "postalCode" → "postal code"
    private static func camelCaseToWords(_ text: String) -> String {
        var result = ""
        for char in text {
            if char.isUppercase && !result.isEmpty {
                result += " "
            }
            result += String(char).lowercased()
        }
        return result
    }
}
