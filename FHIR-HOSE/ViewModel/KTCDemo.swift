//
//  KTCDemo.swift
//  FHIR-HOSE
//
//  Created by Claude Code on 1/27/26.
//

import Foundation
import NaturalLanguage
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

enum KTCFieldType: String {
    case text = "text"
    case checkbox = "checkbox"
    case signature = "signature"
    case date = "date"
}

struct KTCField: Identifiable {
    let id = UUID()
    var label: String
    var labelBoundingBox: CGRect
    var fieldType: KTCFieldType = .text
    var mappedKeypath: String?
    var value: String = ""
    var matchConfidence: Double = 0  // 0-1 confidence score for the match
    var matchMethod: String?  // How the match was made (synonym, embedding, token)
    var detectedValue: String?  // Value found on the form via spatial analysis
    var valueBoundingBox: CGRect?  // Where the value was found
    var isChecked: Bool?  // For checkbox fields
    var adjustedValueBox: CGRect?  // User-adjusted position for the value (normalized Vision coords)
}

/// Represents a detected checkbox on the form.
struct KTCCheckbox {
    let boundingBox: CGRect
    var isChecked: Bool
    var associatedText: String?  // Text near the checkbox (e.g., "Male", "Female")
    var groupId: UUID?  // If part of a checkbox group
}

/// Represents a group of mutually exclusive checkboxes (e.g., Male/Female, Yes/No).
struct KTCCheckboxGroup: Identifiable {
    let id = UUID()
    let boundingBox: CGRect  // Combined bounding box of the group
    var options: [KTCCheckbox]  // The checkboxes in this group
    var groupLabel: String?  // e.g., "Sex", "Gender" - the label for the whole group
    var mappedKeypath: String?  // Patient data keypath this group maps to
    var selectedIndex: Int?  // Which option is selected (auto-filled)
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
    @Published var checkboxGroups: [KTCCheckboxGroup] = []  // Detected checkbox groups
    @Published var patientData: [String: String] = [:]  // flattened keypath → value
    @Published var signatureImage: UIImage? = nil  // User's signature as UIImage
    @Published var hasSignature: Bool = false  // Whether user has signed
    @Published var signatureFieldId: UUID? = nil  // Which field to place signature at (if any)
    @Published var signatureSize: CGSize = CGSize(width: 150, height: 60)  // Adjustable signature display size
    @Published var signatureNormalizedPosition: CGPoint? = nil  // Manual position in normalized coords (0-1)

    /// Sorted keypath list for Picker UI.
    var sortedKeypaths: [String] {
        patientData.keys.sorted()
    }

    /// Human-readable display name for a keypath, e.g. "patient.address.city" → "Address > City".
    func displayName(for keypath: String) -> String {
        // Special display names for computed fields
        switch keypath {
        case "_computed.todayDate": return "Today's Date"
        case "_computed.patientAge": return "Patient Age"
        case "_computed.dobFormatted": return "DOB (Formatted)"
        case "patient.fullName": return "Full Name"
        case "patient.fullAddress": return "Full Address"
        default: break
        }
        let parts = keypath.components(separatedBy: ".")
        // Drop known prefixes
        let meaningful: [String]
        if parts.first == "patient" || parts.first == "_computed" {
            meaningful = Array(parts.dropFirst())
        } else {
            meaningful = parts
        }
        return meaningful.map { Self.camelCaseToTitleCase($0) }.joined(separator: " > ")
    }

    /// Convert camelCase to Title Case words, also splitting before digits.
    /// "postalCode" → "Postal Code", "line1" → "Line 1", "memberId" → "Member ID"
    private static func camelCaseToTitleCase(_ text: String) -> String {
        var words: [String] = []
        var current = ""
        var prevWasDigit = false
        for char in text {
            let isDigit = char.isNumber
            if (char.isUppercase || (isDigit && !prevWasDigit)) && !current.isEmpty {
                words.append(current)
                current = String(char).lowercased()
            } else {
                current += String(char)
            }
            prevWasDigit = isDigit
        }
        if !current.isEmpty { words.append(current) }
        // Title-case each word, with special handling for "id" → "ID"
        return words.map { word in
            let lower = word.lowercased()
            if lower == "id" { return "ID" }
            if lower == "dob" { return "DOB" }
            if lower == "ssn" { return "SSN" }
            if lower == "mrn" { return "MRN" }
            return word.prefix(1).uppercased() + word.dropFirst()
        }.joined(separator: " ")
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

    /// Update the value position for a field (used when user drags the badge).
    /// Position is stored in normalized Vision coordinates (0-1).
    func updateFieldValueBox(id: UUID, normalizedBox: CGRect) {
        guard let idx = fields.firstIndex(where: { $0.id == id }) else { return }
        // Validate and clamp the normalized box to [0, 1] range
        let clampedBox = CGRect(
            x: max(0, min(1, normalizedBox.origin.x)),
            y: max(0, min(1, normalizedBox.origin.y)),
            width: max(0.01, min(1, normalizedBox.width)),
            height: max(0.01, min(1, normalizedBox.height))
        )
        fields[idx].adjustedValueBox = clampedBox
        let fieldLabel = fields[idx].label
        logger.info("Updated value box for field '\(fieldLabel)'")
    }

    /// Set which field should receive the signature.
    func setSignatureField(id: UUID?) {
        signatureFieldId = id
        if let id = id, let field = fields.first(where: { $0.id == id }) {
            logger.info("Signature will be placed at field: '\(field.label)'")
        } else {
            logger.info("Signature field cleared")
        }
    }

    /// Get the field designated for signature placement.
    var signatureField: KTCField? {
        if let id = signatureFieldId {
            return fields.first { $0.id == id }
        }
        // Fall back to auto-detected signature field
        return fields.first { $0.fieldType == .signature }
    }

    /// Update signature position (for manual dragging).
    /// Position should be in normalized coordinates (0-1).
    func updateSignatureNormalizedPosition(_ normalizedPos: CGPoint) {
        // Validate and clamp to [0, 1] range
        let clampedPos = CGPoint(
            x: max(0, min(1, normalizedPos.x)),
            y: max(0, min(1, normalizedPos.y))
        )
        signatureNormalizedPosition = clampedPos
        logger.info("Signature position updated to normalized (\(clampedPos.x), \(clampedPos.y))")
    }

    // MARK: - Checkbox Group Editing

    /// Toggle a checkbox within a group. For multi-option groups, only one can be selected.
    func toggleCheckbox(groupIndex: Int, optionIndex: Int) {
        guard groupIndex < checkboxGroups.count,
              optionIndex < checkboxGroups[groupIndex].options.count else { return }

        let isMultiOption = checkboxGroups[groupIndex].options.count > 1

        if isMultiOption {
            // Mutually exclusive: uncheck all others, check this one
            for i in checkboxGroups[groupIndex].options.indices {
                checkboxGroups[groupIndex].options[i].isChecked = (i == optionIndex)
            }
            checkboxGroups[groupIndex].selectedIndex = optionIndex
        } else {
            // Single checkbox: just toggle it
            checkboxGroups[groupIndex].options[optionIndex].isChecked.toggle()
            checkboxGroups[groupIndex].selectedIndex = checkboxGroups[groupIndex].options[optionIndex].isChecked ? 0 : nil
        }

        logger.info("Toggled checkbox group \(groupIndex) option \(optionIndex)")
    }

    // MARK: - Signature Handling

    /// Update the signature image.
    func updateSignature(_ image: UIImage?) {
        signatureImage = image
        hasSignature = image != nil
        let hasSig = hasSignature
        logger.info("Signature updated: hasSignature=\(hasSig)")
    }

    /// Clear the signature.
    func clearSignature() {
        signatureImage = nil
        hasSignature = false
        logger.info("Signature cleared")
    }

    // MARK: - Export

    /// Build a readable text summary of all filled fields.
    func filledDataText() -> String {
        var lines: [String] = []
        lines.append("Kill-The-Clipboard — Filled Form Data")
        lines.append(String(repeating: "=", count: 38))
        lines.append("")

        // Checkbox groups
        let filledGroups = checkboxGroups.filter { $0.selectedIndex != nil && $0.options.count > 1 }
        if !filledGroups.isEmpty {
            lines.append("Checkbox Selections:")
            for group in filledGroups {
                let label = group.groupLabel ?? "Choice"
                if let idx = group.selectedIndex, idx < group.options.count {
                    let selected = group.options[idx].associatedText ?? "Option \(idx + 1)"
                    lines.append("  \(label): \(selected)")
                }
            }
            lines.append("")
        }

        // Text fields
        let matched = fields.filter { $0.mappedKeypath != nil && !$0.value.isEmpty }
        let unmatched = fields.filter { $0.mappedKeypath == nil }

        if matched.isEmpty && filledGroups.isEmpty {
            lines.append("No fields were matched to patient data.")
        } else if !matched.isEmpty {
            lines.append("Text Fields:")
            for field in matched {
                lines.append("  \(field.label): \(field.value)")
            }
        }

        if !unmatched.isEmpty {
            lines.append("")
            lines.append("Unmatched Fields:")
            for field in unmatched {
                let val = field.value.isEmpty ? "(empty)" : field.value
                lines.append("  - \(field.label): \(val)")
            }
        }

        // Signature status
        if hasSignature {
            lines.append("")
            lines.append("Signature: ✓ Signed")
        }

        lines.append("")
        lines.append("Generated by FHIR-HOSE KTC Demo")
        return lines.joined(separator: "\n")
    }

    /// Copy the filled-data summary to the system clipboard.
    func copyToClipboard() {
        let text = filledDataText()
        UIPasteboard.general.string = text
        logger.info("Copied filled data to clipboard (\(text.count) chars)")
    }

    /// Generate a PDF with the scanned image as background and filled values drawn on.
    /// Returns a temporary file URL for sharing, or nil on failure.
    func generateFilledPDF() -> URL? {
        guard let image = pages.first else { return nil }

        let pageSize = CGSize(width: image.size.width, height: image.size.height)
        let pdfData = NSMutableData()

        UIGraphicsBeginPDFContextToData(pdfData, CGRect(origin: .zero, size: pageSize), [
            kCGPDFContextTitle as String: "Filled Form" as NSString
        ])
        UIGraphicsBeginPDFPage()

        guard let context = UIGraphicsGetCurrentContext() else {
            UIGraphicsEndPDFContext()
            return nil
        }

        // Draw the scanned image as background
        image.draw(in: CGRect(origin: .zero, size: pageSize))

        // Draw checkmarks for selected checkboxes
        for group in checkboxGroups {
            guard let selectedIdx = group.selectedIndex, selectedIdx < group.options.count else { continue }
            let option = group.options[selectedIdx]
            let box = option.boundingBox

            // Convert Vision coords to PDF coords
            let x = box.origin.x * pageSize.width
            let y = (1.0 - box.origin.y - box.height) * pageSize.height
            let h = box.height * pageSize.height

            // Draw an X mark inside the checkbox (more visible than ✓)
            let checkSize = max(10, min(18, h * 0.7))
            let checkFont = UIFont.systemFont(ofSize: checkSize, weight: .bold)
            let checkAttrs: [NSAttributedString.Key: Any] = [
                .font: checkFont,
                .foregroundColor: UIColor.black
            ]
            let checkStr = "X" as NSString
            checkStr.draw(at: CGPoint(x: x + 2, y: y), withAttributes: checkAttrs)
        }

        // Build set of keypaths that are handled by checkbox groups (don't draw as text)
        let checkboxKeypaths = Set(checkboxGroups.compactMap { $0.mappedKeypath })

        // Draw filled values - detect if input area is below or to the right
        let filledFields = fields.filter { !$0.value.isEmpty }
        for field in filledFields {
            // Skip fields that are handled by checkbox groups
            if let keypath = field.mappedKeypath, checkboxKeypaths.contains(keypath) {
                continue
            }

            // Skip checkbox-type fields (they're handled separately)
            if field.fieldType == .checkbox {
                continue
            }

            // Skip signature fields (handled separately)
            if field.fieldType == .signature {
                continue
            }

            // Skip single-letter values that are likely checkbox indicators (M, F, Y, N)
            let trimmedValue = field.value.trimmingCharacters(in: .whitespaces)
            if trimmedValue.count == 1 && "MFYNmfyn".contains(trimmedValue) {
                continue
            }

            // Use adjusted value box if user dragged it, otherwise calculate from label
            let valueX: CGFloat
            let valueY: CGFloat

            if let adjustedBox = field.adjustedValueBox {
                // User manually positioned this value
                valueX = adjustedBox.origin.x * pageSize.width
                valueY = (1.0 - adjustedBox.origin.y - adjustedBox.height) * pageSize.height
            } else {
                // Calculate default position based on label
                let box = field.labelBoundingBox
                let x = box.origin.x * pageSize.width
                let y = (1.0 - box.origin.y - box.height) * pageSize.height
                let w = box.width * pageSize.width
                let h = box.height * pageSize.height

                // Place BELOW label if short, otherwise to the RIGHT
                let labelLooksLikeHeader = field.label.count < 20 && !field.label.contains(":")
                if labelLooksLikeHeader {
                    valueX = x
                    valueY = y + h + 4
                } else {
                    valueX = x + w + 6
                    valueY = y
                }
            }

            let labelBox = field.labelBoundingBox
            let h = labelBox.height * pageSize.height

            // Font size proportional to bounding box height, clamped
            let fontSize = max(10, min(18, h * 0.8))
            let font = UIFont.systemFont(ofSize: fontSize, weight: .medium)
            let attributes: [NSAttributedString.Key: Any] = [
                .font: font,
                .foregroundColor: UIColor(red: 0.1, green: 0.1, blue: 0.5, alpha: 1.0) // dark blue
            ]

            let valueStr = field.value as NSString
            let textSize = valueStr.size(withAttributes: attributes)

            // Draw white background rect for legibility
            let textRect = CGRect(x: valueX - 2, y: valueY - 1, width: textSize.width + 4, height: textSize.height + 2)
            context.setFillColor(UIColor.white.withAlphaComponent(0.85).cgColor)
            context.fill(textRect)

            // Draw the text
            valueStr.draw(at: CGPoint(x: valueX, y: valueY), withAttributes: attributes)
        }

        // Draw signature if present
        if self.hasSignature, let sigImage = self.signatureImage {
            let sigWidth = self.signatureSize.width * (pageSize.width / 400)  // Scale to page
            let sigHeight = self.signatureSize.height * (pageSize.height / 600)
            let sigRect: CGRect

            if let normalizedPos = self.signatureNormalizedPosition {
                // User manually positioned the signature
                let x = normalizedPos.x * pageSize.width - sigWidth / 2
                let y = (1.0 - normalizedPos.y) * pageSize.height - sigHeight / 2
                sigRect = CGRect(x: x, y: y, width: sigWidth, height: sigHeight)
            } else if let field = self.signatureField {
                // Use signature field location
                let box = field.labelBoundingBox
                let x = box.origin.x * pageSize.width
                let y = (1.0 - box.origin.y - box.height) * pageSize.height + 5
                sigRect = CGRect(x: x, y: y, width: sigWidth, height: sigHeight)
            } else {
                // Default: bottom right area
                sigRect = CGRect(
                    x: pageSize.width - sigWidth - 40,
                    y: pageSize.height - sigHeight - 60,
                    width: sigWidth,
                    height: sigHeight
                )
            }

            sigImage.draw(in: sigRect)
        }

        UIGraphicsEndPDFContext()

        // Save to temp file
        let tempURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("KTC-FilledForm.pdf")
        do {
            try pdfData.write(to: tempURL, options: .atomic)
            logger.info("Generated filled PDF at \(tempURL.path) (\(pdfData.length) bytes, \(filledFields.count) values)")
            return tempURL
        } catch {
            logger.error("Failed to write PDF: \(error.localizedDescription)")
            return nil
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
                // 3. Detect checkboxes, group them, and classify field types
                let checkboxes = Self.detectCheckboxes(from: lines)
                var checkboxGroups = Self.groupCheckboxes(checkboxes, allLines: lines)
                Self.classifyFieldTypes(&detectedFields, checkboxes: checkboxes, allLines: lines)
                // 4. Spatial analysis: find values near labels
                Self.associateValuesWithLabels(&detectedFields, allLines: lines)
                // 5. Load + flatten patient JSON
                let data = KTCPatientDataLoader.loadAndFlatten()
                // 6. Fuzzy-match labels → keypaths and fill values
                KTCPatientDataLoader.applyMappings(to: &detectedFields, using: data)
                // 7. Auto-check checkboxes based on patient data
                Self.autoCheckCheckboxGroups(&checkboxGroups, using: data)

                await MainActor.run {
                    self.recognizedLines = lines
                    self.fields = detectedFields
                    self.checkboxGroups = checkboxGroups
                    self.patientData = data
                    let withValues = detectedFields.filter { $0.detectedValue != nil }.count
                    let checkboxFields = detectedFields.filter { $0.fieldType == .checkbox }.count
                    let groupCount = checkboxGroups.count
                    let autoChecked = checkboxGroups.filter { $0.selectedIndex != nil }.count
                    self.logger.info("OCR complete: \(lines.count) lines, \(detectedFields.count) fields (\(withValues) detected, \(checkboxFields) checkboxes, \(groupCount) groups, \(autoChecked) auto-checked), \(data.count) keypaths")
                    // Haptic feedback on completion
                    UINotificationFeedbackGenerator().notificationOccurred(.success)
                    self.phase = .editing
                }
            } catch {
                await MainActor.run {
                    self.logger.error("OCR failed: \(error.localizedDescription)")
                    UINotificationFeedbackGenerator().notificationOccurred(.error)
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

            // Enhanced OCR settings for better form recognition
            request.recognitionLevel = .accurate
            request.usesLanguageCorrection = true
            request.recognitionLanguages = ["en-US"]
            request.minimumTextHeight = 0.005  // Detect even smaller text
            request.automaticallyDetectsLanguage = false
            // Use latest Vision revision for better accuracy
            if #available(iOS 16.0, *) {
                request.revision = VNRecognizeTextRequestRevision3
            }

            let handler = VNImageRequestHandler(cgImage: cgImage, options: [:])
            do {
                try handler.perform([request])
            } catch {
                continuation.resume(throwing: error)
            }
        }
    }

    // MARK: - Manual Field Addition

    /// Add a field manually with specified label and input locations.
    func addManualField(label: String, labelBox: CGRect, inputBox: CGRect?) {
        var field = KTCField(
            label: label,
            labelBoundingBox: labelBox
        )

        // If input box specified, store it for value placement
        if let inputBox = inputBox {
            field.valueBoundingBox = inputBox
        }

        // Try to match to patient data
        if let match = KTCPatientDataLoader.fuzzyMatch(label: label, in: patientData) {
            field.mappedKeypath = match.keypath
            field.value = match.value
            field.matchConfidence = match.confidence
            field.matchMethod = match.method
        }

        fields.append(field)
        logger.info("Added manual field: '\(label)'")
    }

    /// Remove a field by ID.
    func removeField(id: UUID) {
        fields.removeAll { $0.id == id }
        logger.info("Removed field with id: \(id)")
    }

    // MARK: - Heading Detection (to filter out)

    /// Patterns that indicate a line is a section heading, not a field label.
    private static let headingPatterns: [String] = [
        "patient information", "personal information", "insurance information",
        "medical history", "health history", "family history",
        "emergency contact", "contact information", "billing information",
        "authorization", "consent", "agreement", "notice", "acknowledgment",
        "section", "part", "page", "form", "instructions", "please read",
        "important", "required", "office use only", "do not write",
        "demographic", "registration", "intake", "new patient",
        "hipaa", "privacy", "disclosure", "release of information"
    ]

    /// Check if a line appears to be a section heading rather than a field label.
    private nonisolated static func isHeading(_ text: String, boundingBox: CGRect) -> Bool {
        let lower = text.lowercased().trimmingCharacters(in: .whitespaces)

        // Only filter if it EXACTLY matches a heading pattern (not just contains)
        for pattern in headingPatterns {
            // Must be a significant match, not just contain the word
            if lower == pattern || lower.hasPrefix(pattern + ":") || lower.hasPrefix(pattern + " -") {
                return true
            }
        }

        // All caps text that's relatively long is likely a heading (not short labels like "DOB")
        let stripped = text.trimmingCharacters(in: .punctuationCharacters.union(.whitespaces))
        if stripped.count >= 10 && stripped.count <= 50 && stripped == stripped.uppercased() && stripped.contains(" ") {
            // Multi-word all-caps longer text is likely a heading
            return true
        }

        // Text that spans a very large horizontal portion is likely a heading/title
        if boundingBox.width > 0.6 && text.count > 30 {
            return true
        }

        return false
    }

    // MARK: - Input Area Detection

    /// Represents a detected input area (underline, box, or blank space).
    struct InputArea {
        let boundingBox: CGRect
        let type: InputType

        enum InputType {
            case underline      // _____ or ------ pattern
            case blankSpace     // Empty area next to label
            case textBox        // Rectangular input area
        }
    }

    /// Detect input areas (underlines, blank spaces) from OCR text.
    nonisolated static func detectInputAreas(from lines: [KTCRecognizedLine]) -> [InputArea] {
        var areas: [InputArea] = []

        for line in lines {
            let text = line.text

            // Detect underline patterns: sequences of _ or -
            let underlinePattern = try? NSRegularExpression(pattern: "[_\\-]{3,}", options: [])
            if let matches = underlinePattern?.matches(in: text, options: [], range: NSRange(text.startIndex..., in: text)), !matches.isEmpty {
                // This line contains an underline - the input area is where the underline is
                areas.append(InputArea(boundingBox: line.boundingBox, type: .underline))
            }
        }

        return areas
    }

    // MARK: - Label Detection Heuristics

    /// Common label keywords found on medical forms.
    /// NOTE: Avoid generic words that could match section headings.
    private static let labelKeywords: Set<String> = [
        // Identity - specific field labels
        "name", "first", "last", "middle",
        "full name", "first name", "last name", "middle name", "mi",
        "patient name", "legal name", "print name", "printed name",
        // DOB / Age
        "dob", "date of birth", "birth date", "birthday", "age", "birthdate",
        // Sex / Gender
        "sex", "gender",
        // Contact - specific
        "phone", "telephone", "cell", "mobile", "fax", "phone number",
        "home phone", "cell phone", "work phone", "daytime phone",
        "email", "e-mail", "email address",
        // Address - specific field labels
        "address", "street", "street address", "apt", "suite", "unit",
        "city", "state", "zip", "postal", "zip code", "postal code",
        "county", "country",
        // ID numbers - specific
        "ssn", "social security", "mrn", "medical record number",
        "account number", "id number", "member id", "subscriber id",
        "driver license", "license number",
        // Insurance - specific field labels
        "payer", "carrier", "insurer", "plan name",
        "member id", "subscriber", "group", "group id", "group number",
        "policy number", "copay", "co-pay", "bin", "pcn", "rx bin", "rx pcn",
        // Employment
        "employer", "employer name", "occupation", "company",
        // Emergency contact fields
        "emergency contact", "relationship", "notify",
        // Clinical - specific field labels (not section headers)
        "allergies", "medications", "pharmacy", "pharmacy name", "pharmacy phone",
        "primary diagnosis", "referring physician", "pcp",
        // Administrative - specific field labels
        "signature", "patient signature", "date", "today's date",
        "date signed", "reason for visit",
        // Vitals
        "height", "weight", "blood pressure", "bp", "temperature", "pulse",
        // Demographics - specific
        "race", "ethnicity", "marital status", "preferred language",
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

            // Skip if this looks like a heading
            if isHeading(trimmed, boundingBox: line.boundingBox) {
                continue
            }

            // Strategy 1: Line contains a colon → text before colon is the label
            // Also extract any value after the colon
            if let colonIdx = trimmed.firstIndex(of: ":") {
                let labelPart = String(trimmed[trimmed.startIndex..<colonIdx])
                    .trimmingCharacters(in: .whitespaces)

                // Skip if the label part looks like a heading
                if isHeading(labelPart, boundingBox: line.boundingBox) {
                    continue
                }

                if !labelPart.isEmpty && labelPart.count >= 2 && labelPart.count <= 50 {
                    let normalized = labelPart.lowercased()
                    if !seenLabels.contains(normalized) {
                        seenLabels.insert(normalized)

                        var field = KTCField(
                            label: labelPart,
                            labelBoundingBox: line.boundingBox
                        )

                        // Check for value after colon (not just underlines)
                        let afterColon = String(trimmed[trimmed.index(after: colonIdx)...])
                            .trimmingCharacters(in: .whitespaces)
                        let cleanedValue = afterColon
                            .replacingOccurrences(of: "_", with: "")
                            .replacingOccurrences(of: "-", with: "")
                            .trimmingCharacters(in: .whitespaces)

                        if !cleanedValue.isEmpty && cleanedValue.count >= 2 {
                            // There's actual text after the colon - it might be pre-filled
                            field.detectedValue = cleanedValue
                        }

                        // Check if there's an underline pattern indicating input area
                        if afterColon.contains("__") || afterColon.contains("--") {
                            field.fieldType = .text  // Explicitly a text input field
                        }

                        fields.append(field)
                    }
                    continue
                }
            }

            // Strategy 2: Line contains underscores/dashes (fill-in-the-blank pattern)
            // e.g. "Name ___________" or "DOB __/__/__"
            // Parse out the label portion before the underlines
            if trimmed.contains("__") || (trimmed.contains("--") && !trimmed.hasPrefix("--")) {
                // Find where the underlines start
                if let underlineStart = trimmed.firstIndex(of: "_") ?? trimmed.range(of: "--")?.lowerBound {
                    let labelPart = String(trimmed[trimmed.startIndex..<underlineStart])
                        .trimmingCharacters(in: .whitespaces)

                    if !labelPart.isEmpty && labelPart.count >= 2 && labelPart.count <= 50 {
                        // Skip if looks like heading
                        if isHeading(labelPart, boundingBox: line.boundingBox) {
                            continue
                        }

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

                // Fallback: clean the whole thing
                let stripped = trimmed
                    .replacingOccurrences(of: "_", with: " ")
                    .replacingOccurrences(of: "-", with: " ")
                    .trimmingCharacters(in: .whitespaces)
                    .components(separatedBy: .whitespaces)
                    .filter { !$0.isEmpty }
                    .joined(separator: " ")

                if !stripped.isEmpty && stripped.count >= 2 && stripped.count <= 50 {
                    if isHeading(stripped, boundingBox: line.boundingBox) {
                        continue
                    }
                    let normalized = stripped.lowercased()
                    if !seenLabels.contains(normalized) {
                        seenLabels.insert(normalized)
                        fields.append(KTCField(
                            label: stripped,
                            labelBoundingBox: line.boundingBox
                        ))
                    }
                    continue
                }
            }

            // Strategy 3: Line matches a known keyword (but not a heading)
            let lower = trimmed.lowercased()
            let matched = labelKeywords.contains { keyword in
                lower == keyword
                    || lower.hasPrefix(keyword + " ")
                    || lower.hasPrefix(keyword + "/")
                    || lower.hasPrefix(keyword + "(")
                    || lower.hasSuffix(" " + keyword)
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

    // MARK: - Spatial Analysis

    /// Find values on the form that are spatially associated with each label.
    /// Looks for text to the RIGHT of or BELOW each label bounding box.
    nonisolated static func associateValuesWithLabels(_ fields: inout [KTCField], allLines: [KTCRecognizedLine]) {
        // Build a set of label bounding boxes to exclude from value candidates
        let labelBoxes = Set(fields.map { $0.labelBoundingBox })

        for i in fields.indices {
            let label = fields[i]
            let box = label.labelBoundingBox

            // Find candidate value lines (not already used as labels)
            var bestCandidate: (line: KTCRecognizedLine, score: Double)?

            for line in allLines {
                // Skip if this line's box is a label
                if labelBoxes.contains(line.boundingBox) { continue }
                // Skip low confidence
                if line.confidence < 0.5 { continue }
                // Skip very short text (likely noise)
                if line.text.trimmingCharacters(in: .whitespaces).count < 2 { continue }

                let lineBox = line.boundingBox
                let score = spatialScore(labelBox: box, candidateBox: lineBox)

                if score > 0 {
                    if bestCandidate == nil || score > bestCandidate!.score {
                        bestCandidate = (line, score)
                    }
                }
            }

            if let best = bestCandidate {
                fields[i].detectedValue = best.line.text.trimmingCharacters(in: .whitespaces)
                fields[i].valueBoundingBox = best.line.boundingBox
            }
        }
    }

    /// Calculate a spatial affinity score between a label and a potential value.
    /// Higher score = better candidate. Returns 0 if not a valid spatial relationship.
    /// Vision coords: normalized (0-1), origin bottom-left.
    private nonisolated static func spatialScore(labelBox: CGRect, candidateBox: CGRect) -> Double {
        // Horizontal overlap/proximity
        let labelMidY = labelBox.midY
        let candMidY = candidateBox.midY
        let verticalDistance = abs(labelMidY - candMidY)
        let labelHeight = labelBox.height

        // Case 1: Same line (to the RIGHT of label)
        // Candidate should be roughly same Y level and to the right
        if verticalDistance < labelHeight * 1.5 {
            let horizontalGap = candidateBox.minX - labelBox.maxX
            // Must be to the right, with reasonable gap
            if horizontalGap > 0 && horizontalGap < 0.3 {
                // Score: closer horizontally = better, penalize vertical misalignment
                let hScore = 1.0 - (horizontalGap / 0.3)
                let vPenalty = verticalDistance / (labelHeight * 1.5)
                return hScore * (1.0 - vPenalty * 0.5) * 1.0  // weight for "right of"
            }
        }

        // Case 2: Line below (candidate Y is lower in Vision coords)
        // Candidate should be roughly same X (or slightly right) and below
        let labelMidX = labelBox.midX
        let candMidX = candidateBox.midX
        let horizontalDistance = abs(labelMidX - candMidX)

        if candidateBox.maxY < labelBox.minY {  // candidate is below label (lower Y in Vision)
            let verticalGap = labelBox.minY - candidateBox.maxY
            // Must be reasonably close vertically and horizontally aligned
            if verticalGap < 0.1 && horizontalDistance < labelBox.width * 2 {
                let vScore = 1.0 - (verticalGap / 0.1)
                let hPenalty = horizontalDistance / (labelBox.width * 2)
                return vScore * (1.0 - hPenalty * 0.5) * 0.8  // slightly lower weight for "below"
            }
        }

        return 0
    }

    // MARK: - Checkbox Detection

    /// Characters that indicate an unchecked checkbox in OCR.
    private static let uncheckedPatterns: Set<Character> = ["☐", "□", "◯", "○", "◻"]
    /// Characters that indicate a checked checkbox in OCR.
    private static let checkedPatterns: Set<Character> = ["☑", "☒", "■", "●", "◼", "✓", "✔", "✗", "✘", "×"]

    /// Detect checkboxes from OCR lines and return them with associated text.
    nonisolated static func detectCheckboxes(from lines: [KTCRecognizedLine]) -> [KTCCheckbox] {
        var checkboxes: [KTCCheckbox] = []

        for line in lines {
            let text = line.text
            var currentIndex = text.startIndex

            while currentIndex < text.endIndex {
                let char = text[currentIndex]

                // Check for checkbox character patterns
                let isUnchecked = uncheckedPatterns.contains(char)
                let isChecked = checkedPatterns.contains(char)

                if isUnchecked || isChecked {
                    // Extract associated text (after the checkbox on the same line)
                    let afterIndex = text.index(after: currentIndex)
                    let associatedText = afterIndex < text.endIndex
                        ? String(text[afterIndex...]).trimmingCharacters(in: .whitespaces)
                        : nil

                    // Clean up associated text - take first word if it's a simple option
                    var cleanedText = associatedText
                    if let at = associatedText {
                        // If the text contains another checkbox, only take text before it
                        let words = at.components(separatedBy: .whitespaces)
                        if let firstWord = words.first, !firstWord.isEmpty {
                            // Check if first word is a common checkbox option
                            let lower = firstWord.lowercased()
                            if ["male", "female", "yes", "no", "m", "f", "married", "single", "divorced", "widowed"].contains(lower) {
                                cleanedText = firstWord
                            }
                        }
                    }

                    checkboxes.append(KTCCheckbox(
                        boundingBox: line.boundingBox,
                        isChecked: isChecked,
                        associatedText: cleanedText?.isEmpty == true ? nil : cleanedText
                    ))
                }

                // Also check for text patterns like "[x]", "[ ]", "(x)", "( )", "[ x ]"
                if char == "[" || char == "(" {
                    let closeChar: Character = char == "[" ? "]" : ")"
                    if let closeIndex = text[currentIndex...].firstIndex(of: closeChar) {
                        let inside = String(text[text.index(after: currentIndex)..<closeIndex])
                            .trimmingCharacters(in: .whitespaces)
                            .lowercased()

                        let isEmpty = inside.isEmpty || inside == " "
                        let isFilled = inside == "x" || inside == "✓" || inside == "*"

                        if isEmpty || isFilled {
                            let afterClose = text.index(after: closeIndex)
                            var associatedText = afterClose < text.endIndex
                                ? String(text[afterClose...]).trimmingCharacters(in: .whitespaces)
                                : nil

                            // Clean up - take first meaningful word
                            if let at = associatedText {
                                let words = at.components(separatedBy: .whitespaces)
                                if let firstWord = words.first, !firstWord.isEmpty {
                                    let lower = firstWord.lowercased()
                                    if ["male", "female", "yes", "no", "m", "f", "married", "single"].contains(lower) {
                                        associatedText = firstWord
                                    }
                                }
                            }

                            checkboxes.append(KTCCheckbox(
                                boundingBox: line.boundingBox,
                                isChecked: isFilled,
                                associatedText: associatedText?.isEmpty == true ? nil : associatedText
                            ))
                            currentIndex = closeIndex
                        }
                    }
                }

                currentIndex = text.index(after: currentIndex)
            }

            // Also detect implicit checkbox patterns: "☐Male ☐Female" or "□ Male □ Female" style
            // Look for patterns where checkbox-like words appear after common symbols
            let lower = text.lowercased()
            if (lower.contains("male") || lower.contains("female")) && !checkboxes.contains(where: { $0.boundingBox == line.boundingBox }) {
                // This line mentions male/female but we didn't detect explicit checkboxes
                // Create implicit checkboxes based on text patterns
                let patterns = [
                    ("male", false),
                    ("female", false)
                ]
                for (pattern, _) in patterns {
                    if let range = lower.range(of: pattern) {
                        let word = String(text[range])
                        checkboxes.append(KTCCheckbox(
                            boundingBox: line.boundingBox,
                            isChecked: false,
                            associatedText: word.capitalized
                        ))
                    }
                }
            }
        }

        return checkboxes
    }

    // MARK: - Checkbox Grouping

    /// Known checkbox group patterns that should be matched together.
    /// Maps group label patterns → (keypath, option values to match)
    private static let checkboxGroupPatterns: [(labelPatterns: [String], keypath: String, optionMappings: [String: String])] = [
        // Sex/Gender: "M", "F", "Male", "Female" → patient.sex
        (["sex", "gender", "sex gender", "male female", "m f"],
         "patient.sex",
         ["male": "M", "m": "M", "female": "F", "f": "F"]),

        // Yes/No patterns (generic - could map to various fields)
        (["yes no", "y n"],
         "",  // No specific keypath - contextual
         ["yes": "true", "y": "true", "no": "false", "n": "false"]),

        // Marital status
        (["marital", "marital status"],
         "patient.maritalStatus",
         ["single": "S", "married": "M", "divorced": "D", "widowed": "W", "separated": "SEP"]),
    ]

    /// Group checkboxes that appear on the same line or are spatially close.
    nonisolated static func groupCheckboxes(_ checkboxes: [KTCCheckbox], allLines: [KTCRecognizedLine]) -> [KTCCheckboxGroup] {
        var groups: [KTCCheckboxGroup] = []
        var usedCheckboxIndices: Set<Int> = []

        // Strategy 1: Group checkboxes on the same OCR line (same boundingBox Y)
        let checkboxesByLine = Dictionary(grouping: checkboxes.enumerated()) { (_, cb) in
            // Round Y to group checkboxes on same line (within tolerance)
            Int(cb.boundingBox.midY * 1000)
        }

        for (_, lineCheckboxes) in checkboxesByLine {
            let indices = lineCheckboxes.map { $0.offset }
            let cbs = lineCheckboxes.map { $0.element }

            // If 2+ checkboxes on same line, they're likely a group
            if cbs.count >= 2 {
                // Combine bounding boxes
                let minX = cbs.map { $0.boundingBox.minX }.min() ?? 0
                let maxX = cbs.map { $0.boundingBox.maxX }.max() ?? 1
                let minY = cbs.map { $0.boundingBox.minY }.min() ?? 0
                let maxY = cbs.map { $0.boundingBox.maxY }.max() ?? 1
                let combinedBox = CGRect(x: minX, y: minY, width: maxX - minX, height: maxY - minY)

                // Try to find a group label from the line text
                let groupLabel = findGroupLabel(for: cbs, allLines: allLines)

                var group = KTCCheckboxGroup(
                    boundingBox: combinedBox,
                    options: cbs,
                    groupLabel: groupLabel
                )

                // Try to match to a known pattern
                if let label = groupLabel?.lowercased() {
                    for pattern in checkboxGroupPatterns {
                        if pattern.labelPatterns.contains(where: { label.contains($0) }) {
                            group.mappedKeypath = pattern.keypath.isEmpty ? nil : pattern.keypath
                            break
                        }
                    }
                }

                // Also check if option texts match known patterns (e.g., "Male", "Female")
                let optionTexts = cbs.compactMap { $0.associatedText?.lowercased() }
                for pattern in checkboxGroupPatterns {
                    let matchCount = optionTexts.filter { pattern.optionMappings.keys.contains($0) }.count
                    if matchCount >= 2 {
                        group.mappedKeypath = pattern.keypath.isEmpty ? nil : pattern.keypath
                        break
                    }
                }

                groups.append(group)
                usedCheckboxIndices.formUnion(indices)
            }
        }

        // Strategy 2: Standalone checkboxes (not part of a group) - create single-option "groups"
        for (idx, cb) in checkboxes.enumerated() {
            if !usedCheckboxIndices.contains(idx) {
                // Single checkbox - might be a yes/no toggle or consent checkbox
                var group = KTCCheckboxGroup(
                    boundingBox: cb.boundingBox,
                    options: [cb],
                    groupLabel: cb.associatedText
                )
                // If it was already checked on the form, mark it
                if cb.isChecked {
                    group.selectedIndex = 0
                }
                groups.append(group)
            }
        }

        return groups
    }

    /// Find a label that describes a checkbox group (e.g., "Sex:" before "Male ☐ Female ☐").
    private nonisolated static func findGroupLabel(for checkboxes: [KTCCheckbox], allLines: [KTCRecognizedLine]) -> String? {
        guard let firstCB = checkboxes.first else { return nil }
        let cbBox = firstCB.boundingBox

        // Look for text to the LEFT of the checkboxes on roughly the same line
        for line in allLines {
            let lineBox = line.boundingBox
            // Same vertical level?
            let verticalOverlap = abs(lineBox.midY - cbBox.midY) < cbBox.height * 1.5
            // To the left?
            let isToLeft = lineBox.maxX < cbBox.minX && (cbBox.minX - lineBox.maxX) < 0.2

            if verticalOverlap && isToLeft {
                let text = line.text.trimmingCharacters(in: .whitespaces)
                // Remove trailing colon
                let cleaned = text.hasSuffix(":") ? String(text.dropLast()) : text
                if !cleaned.isEmpty && cleaned.count < 30 {
                    return cleaned
                }
            }
        }

        // Check if the checkbox option texts themselves indicate the group type
        let optionTexts = checkboxes.compactMap { $0.associatedText?.lowercased() }
        if optionTexts.contains("male") || optionTexts.contains("female") {
            return "Sex"
        }
        if optionTexts.contains("yes") || optionTexts.contains("no") {
            return "Yes/No"
        }
        if optionTexts.contains("married") || optionTexts.contains("single") {
            return "Marital Status"
        }

        return nil
    }

    // MARK: - Auto-Check Logic

    /// Auto-check the correct checkbox in each group based on patient data.
    nonisolated static func autoCheckCheckboxGroups(_ groups: inout [KTCCheckboxGroup], using data: [String: String]) {
        for i in groups.indices {
            // Skip if only one option (standalone checkbox)
            guard groups[i].options.count > 1 else { continue }

            // Try to find the patient value for this group
            var patientValue: String?

            // If group has a mapped keypath, use that
            if let keypath = groups[i].mappedKeypath {
                patientValue = data[keypath]?.lowercased()
            }

            // Also try to infer the keypath from option text
            let optionTexts = groups[i].options.compactMap { $0.associatedText?.lowercased() }
            if optionTexts.contains("male") || optionTexts.contains("female") ||
               optionTexts.contains("m") || optionTexts.contains("f") {
                // This is a sex/gender checkbox - look up patient.sex
                patientValue = data["patient.sex"]?.lowercased()
                groups[i].mappedKeypath = "patient.sex"
            } else if optionTexts.contains("yes") || optionTexts.contains("no") {
                // Yes/No checkbox - might need context
            } else if optionTexts.contains("married") || optionTexts.contains("single") {
                patientValue = data["patient.maritalStatus"]?.lowercased()
                groups[i].mappedKeypath = "patient.maritalStatus"
            }

            guard let value = patientValue else { continue }

            // Find which option matches the patient value
            for (optIdx, option) in groups[i].options.enumerated() {
                guard let optionText = option.associatedText?.lowercased().trimmingCharacters(in: .whitespaces) else { continue }

                // Direct match
                if optionText == value {
                    groups[i].selectedIndex = optIdx
                    groups[i].options[optIdx].isChecked = true
                    break
                }

                // Check against known mappings
                for pattern in checkboxGroupPatterns {
                    if let mappedValue = pattern.optionMappings[optionText],
                       mappedValue.lowercased() == value {
                        groups[i].selectedIndex = optIdx
                        groups[i].options[optIdx].isChecked = true
                        break
                    }
                }

                if groups[i].selectedIndex != nil { break }

                // Fuzzy match for sex/gender: "F" matches "Female", "M" matches "Male"
                if value == "f" && (optionText == "female" || optionText.hasPrefix("female") || optionText == "f") {
                    groups[i].selectedIndex = optIdx
                    groups[i].options[optIdx].isChecked = true
                    break
                }
                if value == "m" && (optionText == "male" || optionText.hasPrefix("male") || optionText == "m") {
                    groups[i].selectedIndex = optIdx
                    groups[i].options[optIdx].isChecked = true
                    break
                }

                // Also handle reverse: patient has "female" and checkbox is "F"
                if (value == "female" || value == "f") && (optionText == "f" || optionText == "female" || optionText.contains("female")) {
                    groups[i].selectedIndex = optIdx
                    groups[i].options[optIdx].isChecked = true
                    break
                }
                if (value == "male" || value == "m") && (optionText == "m" || optionText == "male" || optionText.contains("male")) {
                    groups[i].selectedIndex = optIdx
                    groups[i].options[optIdx].isChecked = true
                    break
                }
            }
        }
    }

    /// Classify field types and create checkbox fields for detected checkboxes.
    nonisolated static func classifyFieldTypes(_ fields: inout [KTCField], checkboxes: [KTCCheckbox], allLines: [KTCRecognizedLine]) {
        // Mark fields as checkbox type if they contain checkbox-related terms
        let checkboxTerms = ["male", "female", "yes", "no", "married", "single", "divorced", "widowed"]
        let checkboxLabelTerms = ["sex", "gender", "marital status", "marital"]

        for i in fields.indices {
            let lower = fields[i].label.lowercased()

            // Check if label IS a checkbox option (yes/no, male/female, etc.)
            if checkboxTerms.contains(where: { lower == $0 || lower.hasPrefix($0 + " ") }) {
                fields[i].fieldType = .checkbox
            }

            // Check if label is a checkbox GROUP label (sex, gender, marital status)
            // These should NOT be filled with text - they have checkbox options
            if checkboxLabelTerms.contains(where: { lower == $0 || lower.hasPrefix($0 + ":") || lower.hasPrefix($0 + " ") }) {
                fields[i].fieldType = .checkbox
            }

            // Check if label is about signatures
            if lower.contains("signature") || lower.contains("sign here") ||
               lower.contains("participant sign") || lower.contains("patient sign") ||
               lower.contains("authorized sign") || lower.contains("sign below") ||
               lower.contains("sign above") || lower == "sign" {
                fields[i].fieldType = .signature
            }

            // Check if label is specifically a date field
            if lower.contains("date") && !lower.contains("birth") {
                fields[i].fieldType = .date
            }
        }

        // Create fields for standalone checkboxes that aren't part of existing fields
        for checkbox in checkboxes {
            if let text = checkbox.associatedText, !text.isEmpty {
                // Check if this checkbox text is already a field
                let alreadyExists = fields.contains { $0.label.lowercased() == text.lowercased() }
                if !alreadyExists && text.count <= 30 {
                    var field = KTCField(
                        label: text,
                        labelBoundingBox: checkbox.boundingBox
                    )
                    field.fieldType = .checkbox
                    field.isChecked = checkbox.isChecked
                    fields.append(field)
                }
            }
        }
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

            // Computed: fullAddress (single-line)
            let addrParts = [
                flat["patient.address.line1"],
                flat["patient.address.line2"],
                flat["patient.address.city"],
                flat["patient.address.state"],
                flat["patient.address.postalCode"]
            ].compactMap { $0 }.filter { !$0.isEmpty }
            if !addrParts.isEmpty {
                flat["patient.fullAddress"] = addrParts.joined(separator: ", ")
            }

            // Computed: today's date (MM/DD/YYYY — US medical form standard)
            let fmt = DateFormatter()
            fmt.dateFormat = "MM/dd/yyyy"
            flat["_computed.todayDate"] = fmt.string(from: Date())

            // Computed: patient age from DOB
            if let dobStr = flat["patient.dateOfBirth"] {
                let isoFmt = DateFormatter()
                isoFmt.dateFormat = "yyyy-MM-dd"
                if let dob = isoFmt.date(from: dobStr) {
                    let age = Calendar.current.dateComponents([.year], from: dob, to: Date()).year ?? 0
                    flat["_computed.patientAge"] = "\(age)"
                }
            }

            // Computed: DOB formatted as MM/DD/YYYY (common US form format)
            if let dobStr = flat["patient.dateOfBirth"] {
                let isoFmt = DateFormatter()
                isoFmt.dateFormat = "yyyy-MM-dd"
                if let dob = isoFmt.date(from: dobStr) {
                    flat["_computed.dobFormatted"] = fmt.string(from: dob)
                }
            }

            logger.info("Loaded \(flat.count) patient keypaths (incl. computed)")
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
        // ===== NAME =====
        (["full name", "patient name", "participant name", "name of patient",
          "patient s name", "patients name", "name last first", "legal name",
          "name last first middle", "print name", "printed name", "name print",
          "name please print", "name of insured", "insured name", "insured s name",
          "name of applicant", "applicant name", "your name", "client name",
          "individual name", "person name", "name of individual"], "patient.fullName"),
        (["first name", "given name", "first", "forename", "fname",
          "patient first name", "legal first name"], "patient.firstName"),
        (["last name", "surname", "family name", "last", "lname",
          "patient last name", "legal last name"], "patient.lastName"),
        (["middle name", "middle initial", "middle", "mi", "m i",
          "middle i", "mname"], "patient.middleName"),

        // ===== DOB / AGE =====
        (["dob", "date of birth", "birth date", "birthday", "birthdate",
          "d o b", "d o b ", "born", "birth", "patient dob", "patient date of birth",
          "patient s date of birth", "date of birth mm dd yyyy", "date of birth mm dd yy",
          "birthdate mm dd yyyy", "b date"], "_computed.dobFormatted"),
        (["age", "patient age", "current age", "age years", "age yrs"], "_computed.patientAge"),

        // ===== SEX / GENDER =====
        (["sex", "gender", "sex gender", "sex or gender", "patient sex",
          "male female", "male   female", "m f", "m or f", "patient gender",
          "biological sex", "sex at birth", "gender identity"], "patient.sex"),

        // ===== PHONE =====
        (["phone", "telephone", "cell", "mobile", "phone number", "tel",
          "cell phone", "home phone", "daytime phone", "phone no", "ph",
          "contact number", "contact phone", "primary phone", "main phone",
          "telephone number", "phone home", "phone cell", "phone mobile",
          "best phone", "preferred phone", "callback number", "patient phone",
          "patient telephone", "evening phone", "day phone"], "patient.phone"),

        // ===== EMAIL =====
        (["email", "e mail", "email address", "e mail address",
          "electronic mail", "patient email", "email id", "e mail id",
          "contact email", "preferred email"], "patient.email"),

        // ===== ADDRESS =====
        (["address", "street", "street address", "address line 1",
          "address 1", "line 1", "mailing address", "home address",
          "street address line 1", "residential address", "residence",
          "current address", "physical address", "patient address",
          "home street address", "street name", "street number",
          "address street", "address number and street"], "patient.address.line1"),
        (["address line 2", "address 2", "line 2", "apt", "suite",
          "unit", "apt suite", "apartment", "apt no", "suite no", "unit no",
          "apt number", "suite number", "unit number", "floor",
          "building", "bldg"], "patient.address.line2"),
        (["city", "city town", "town", "municipality", "city name"], "patient.address.city"),
        (["state", "state province", "st", "province", "state code"], "patient.address.state"),
        (["zip", "zip code", "zipcode", "postal code", "postal",
          "zip postal", "zip 4", "zip 5", "zip plus 4", "zip code 5 digit",
          "postal zip"], "patient.address.postalCode"),
        (["full address", "complete address", "mailing address full",
          "address city state zip", "street city state zip"], "patient.fullAddress"),

        // ===== INSURANCE =====
        (["member id", "member no", "member number", "subscriber id",
          "subscriber", "id number", "identification number",
          "subscriber number", "policy number", "policy no", "policy id",
          "insurance id", "insured id", "insured s id", "contract number",
          "certificate number", "member identification", "id no",
          "insurance member id", "health plan id", "plan id number"], "patient.insurance.memberId"),
        (["group", "group id", "group no", "group number",
          "grp", "grp no", "group plan", "group name", "group policy",
          "employer group", "employer group number", "rx group",
          "rx grp", "rxgrp", "bin", "pcn"], "patient.insurance.groupId"),
        (["payer", "insurance", "insurance company", "plan", "carrier",
          "health plan", "insurance plan", "insurance name",
          "insurance carrier", "plan name", "insurer", "insurance provider",
          "health insurance", "medical insurance", "insurance co",
          "name of insurance", "name of health plan", "name of carrier",
          "primary insurance", "secondary insurance"], "patient.insurance.payer"),

        // ===== TODAY'S DATE =====
        (["today s date", "todays date", "today date", "current date",
          "date signed", "date of signature", "signature date",
          "date today", "today", "date completed", "completion date",
          "form date", "date of form", "effective date",
          "date of authorization", "authorization date"], "_computed.todayDate"),
        // Date (standalone — most forms mean "today's date")
        (["date"], "_computed.todayDate"),
    ]

    // MARK: - Fuzzy Match

    struct MatchResult {
        let keypath: String
        let value: String
        let confidence: Double  // 0-1
        let method: String  // "synonym-exact", "synonym-contains", "token", "embedding"
    }

    /// Try to match a label string to a keypath with confidence scoring.
    static func fuzzyMatch(label: String, in data: [String: String]) -> MatchResult? {
        let normalized = normalize(label)

        // 1. Exact synonym match (confidence: 1.0)
        for entry in synonyms {
            for pattern in entry.patterns {
                if normalized == pattern {
                    if let value = data[entry.keypath] {
                        return MatchResult(keypath: entry.keypath, value: value,
                                           confidence: 1.0, method: "synonym-exact")
                    }
                }
            }
        }

        // 2. Whole-word substring match (confidence: 0.9)
        for entry in synonyms {
            for pattern in entry.patterns {
                if pattern.count >= 3 && containsWholeWords(normalized, pattern: pattern) {
                    if let value = data[entry.keypath] {
                        return MatchResult(keypath: entry.keypath, value: value,
                                           confidence: 0.9, method: "synonym-contains")
                    }
                }
            }
        }

        // 2b. Partial substring match - pattern found anywhere in label (confidence: 0.8)
        for entry in synonyms {
            for pattern in entry.patterns {
                if pattern.count >= 4 && normalized.contains(pattern) {
                    if let value = data[entry.keypath] {
                        return MatchResult(keypath: entry.keypath, value: value,
                                           confidence: 0.8, method: "synonym-partial")
                    }
                }
            }
        }

        // 2c. Label found in pattern (reverse match) - e.g., "city" found in "city town" (confidence: 0.75)
        for entry in synonyms {
            for pattern in entry.patterns {
                if normalized.count >= 3 && pattern.contains(normalized) {
                    if let value = data[entry.keypath] {
                        return MatchResult(keypath: entry.keypath, value: value,
                                           confidence: 0.75, method: "synonym-reverse")
                    }
                }
            }
        }

        // 3. Token overlap with keypath tails (confidence: based on Jaccard score)
        let labelTokens = tokenize(normalized)
        if !labelTokens.isEmpty {
            var bestScore: Double = 0
            var bestKeypath: String?

            for keypath in data.keys {
                let tail = keypath.components(separatedBy: ".").last ?? keypath
                let keypathTokens = tokenize(camelCaseToWords(tail))
                guard !keypathTokens.isEmpty else { continue }

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

            // Lower threshold to 0.3 for more matches
            if bestScore >= 0.3, let keypath = bestKeypath, let value = data[keypath] {
                return MatchResult(keypath: keypath, value: value,
                                   confidence: bestScore * 0.7, method: "token")
            }
        }

        // 4. NLEmbedding semantic similarity (confidence: based on cosine distance)
        if let embeddingMatch = embeddingMatch(label: normalized, in: data) {
            return embeddingMatch
        }

        return nil
    }

    /// Use NLEmbedding to find semantically similar keypaths.
    private static func embeddingMatch(label: String, in data: [String: String]) -> MatchResult? {
        // Get the word embedding model for English
        guard let embedding = NLEmbedding.wordEmbedding(for: .english) else {
            return nil
        }

        var bestDistance: Double = 2.0  // Max cosine distance is 2.0
        var bestKeypath: String?

        for keypath in data.keys {
            // Convert keypath tail to readable words
            let tail = keypath.components(separatedBy: ".").last ?? keypath
            let readableTail = camelCaseToWords(tail)

            // Compare the main word in the label to the keypath tail
            let labelWords = label.lowercased().components(separatedBy: .whitespaces).filter { !$0.isEmpty }
            for labelWord in labelWords {
                // Skip very short words
                if labelWord.count < 3 { continue }

                let tailWords = readableTail.components(separatedBy: .whitespaces).filter { !$0.isEmpty }
                for tailWord in tailWords {
                    if tailWord.count < 3 { continue }

                    // NLEmbedding requires lowercase
                    let distance = embedding.distance(between: labelWord, and: tailWord)
                    if distance < bestDistance {
                        bestDistance = distance
                        bestKeypath = keypath
                    }
                }
            }
        }

        // Convert distance to confidence (distance 0 = identical, distance ~1 = unrelated)
        // Require distance < 0.8 for a match (fairly strict)
        if bestDistance < 0.8, let keypath = bestKeypath, let value = data[keypath] {
            let confidence = max(0, (0.8 - bestDistance) / 0.8) * 0.7  // Scale to max 0.7
            return MatchResult(keypath: keypath, value: value,
                               confidence: confidence, method: "embedding")
        }

        return nil
    }

    /// Apply fuzzy matching to all fields with confidence scoring.
    static func applyMappings(to fields: inout [KTCField], using data: [String: String]) {
        for i in fields.indices {
            let label = fields[i].label
            if let match = fuzzyMatch(label: label, in: data) {
                fields[i].mappedKeypath = match.keypath
                fields[i].value = match.value
                fields[i].matchConfidence = match.confidence
                fields[i].matchMethod = match.method
                logger.info("Mapped '\(label)' → \(match.keypath) [\(match.method), \(String(format: "%.0f", match.confidence * 100))%]")
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
