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
    var mappedKeypath: String?   // Milestone 4
    var value: String = ""       // Milestone 4
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

    // MARK: - OCR

    private func runOCR() {
        guard let image = pages.first, let cgImage = image.cgImage else {
            phase = .error("Could not read the scanned image.")
            return
        }
        logger.info("Starting OCR on first page (\(cgImage.width)x\(cgImage.height))")

        Task.detached(priority: .userInitiated) { [weak self] in
            guard let self else { return }
            do {
                let lines = try await Self.performOCR(on: cgImage, pageIndex: 0)
                let detectedFields = Self.extractLabelCandidates(from: lines)

                await MainActor.run {
                    self.recognizedLines = lines
                    self.fields = detectedFields
                    self.logger.info("OCR complete: \(lines.count) lines, \(detectedFields.count) field candidates")
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
            // Skip low-confidence lines
            guard line.confidence > 0.3 else { continue }

            // Skip very long lines (likely paragraph text, not a label)
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
                // Check if the line starts with or equals the keyword
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
