//
//  ProcessedRecordView.swift
//  FHIR-HOSE
//
//  Created by Eric Hurwitz on 2/24/25.
//

import SwiftUI
import OSLog

struct ProcessedRecordView: View {
    let record: HealthRecord
    @State private var showRawJSON = false
    private let logger = Logger(subsystem: "com.fhirhose.app", category: "ProcessedRecordView")

    var body: some View {
        VStack(spacing: 20) {
            Text("Processed Record")
                .font(.headline)
            
            // Toggle between formatted and raw views (show for any data)
            if record.fhirData != nil || record.healthKitData != nil {
                Picker("View Mode", selection: $showRawJSON) {
                    Text("Formatted").tag(false)
                    Text("Raw JSON").tag(true)
                }
                .pickerStyle(SegmentedPickerStyle())
                .padding(.horizontal)
            }
            
            // Display available data (FHIR or HealthKit)
            if let fhir = record.fhirData {
                ScrollView {
                    if showRawJSON {
                        RawJSONView(data: fhir)
                    } else {
                        FormattedDataView(data: fhir, title: "FHIR Data")
                    }
                }
                .onAppear {
                    logger.info("✅ FHIR data found for record: \(record.filename)")
                    logger.info("📊 FHIR data keys: \(Array(fhir.keys).joined(separator: ", "))")
                    logger.info("📦 FHIR data size: \(fhir.count) top-level keys")
                }
            } else if let healthKit = record.healthKitData {
                ScrollView {
                    if showRawJSON {
                        RawJSONView(data: healthKit)
                    } else {
                        FormattedDataView(data: healthKit, title: "HealthKit Data")
                    }
                }
                .onAppear {
                    logger.info("✅ HealthKit data found for record: \(record.filename)")
                    logger.info("📊 HealthKit data keys: \(Array(healthKit.keys).joined(separator: ", "))")
                    logger.info("📦 HealthKit data size: \(healthKit.count) top-level keys")
                }
            } else {
                Text("No data available.")
                    .foregroundColor(.secondary)
                    .onAppear {
                        logger.warning("❌ No data for record: \(record.filename)")
                        logger.info("📋 Record details:")
                        logger.info("  - Processed: \(record.processed)")
                        logger.info("  - Type: \(String(describing: record.type))")
                        logger.info("  - HealthKit Type: \(record.healthKitType ?? "none")")
                    }
            }
        }
        .padding()
    }

}

struct RawJSONView: View {
    let data: [String: Any]
    
    var body: some View {
        Text(prettyPrintedJSON(data))
            .font(.system(.caption, design: .monospaced))
            .padding()
            .background(Color(.systemGray6))
            .cornerRadius(8)
    }
    
    private func prettyPrintedJSON(_ dict: [String: Any]) -> String {
        guard let data = try? JSONSerialization.data(withJSONObject: dict, options: [.prettyPrinted]),
              let string = String(data: data, encoding: .utf8) else {
            return "\(dict)"
        }
        return string
    }
}

struct FormattedDataView: View {
    let data: [String: Any]
    let title: String
    
    var body: some View {
        LazyVStack(alignment: .leading, spacing: 12) {
            Text(title)
                .font(.title2)
                .fontWeight(.semibold)
                .padding(.bottom, 8)
            
            ForEach(sortedKeys(data), id: \.self) { key in
                VStack(alignment: .leading, spacing: 4) {
                    Text(key.capitalized)
                        .font(.headline)
                        .foregroundColor(.primary)
                    
                    Text(formatValue(data[key], forKey: key))
                        .font(.body)
                        .foregroundColor(.secondary)
                        .padding(.leading, 8)
                }
                .padding(.vertical, 4)
            }
        }
        .padding()
    }
    
    private func sortedKeys(_ dict: [String: Any]) -> [String] {
        return dict.keys.sorted()
    }
    
    private func formatValue(_ value: Any?) -> String {
        guard let value = value else { return "N/A" }
        
        if let dict = value as? [String: Any] {
            return formatDictionary(dict)
        } else if let array = value as? [Any] {
            return formatArray(array)
        } else {
            return "\(value)"
        }
    }
    
    private func formatValue(_ value: Any?, forKey key: String) -> String {
        guard let value = value else { return "N/A" }
        
        // Special handling for FHIR resource fields
        if key.lowercased() == "fhirresource", let fhirString = value as? String {
            return decodeFHIRResourceForDisplay(fhirString)
        }
        
        if let dict = value as? [String: Any] {
            return formatDictionary(dict)
        } else if let array = value as? [Any] {
            return formatArray(array)
        } else {
            return "\(value)"
        }
    }
    
    private func formatDictionary(_ dict: [String: Any]) -> String {
        let items = dict.map { key, value in
            "\(key): \(formatValue(value))"
        }.joined(separator: "\n")
        return items
    }
    
    private func formatArray(_ array: [Any]) -> String {
        let items = array.enumerated().map { index, value in
            "[\(index)] \(formatValue(value))"
        }.joined(separator: "\n")
        return items
    }
    
    /// Decode base64-encoded FHIR resource and format for display
    private func decodeFHIRResourceForDisplay(_ base64String: String) -> String {
        guard let data = Data(base64Encoded: base64String),
              let jsonString = String(data: data, encoding: .utf8) else {
            return "Unable to decode FHIR resource"
        }
        
        do {
            if let jsonObject = try JSONSerialization.jsonObject(with: data) as? [String: Any] {
                return formatFHIRDataForDisplay(jsonObject)
            } else {
                return "FHIR JSON: \(jsonString)"
            }
        } catch {
            return "FHIR JSON (Raw): \(jsonString)"
        }
    }
    
    /// Format FHIR data with medical-friendly field names for display
    private func formatFHIRDataForDisplay(_ data: [String: Any]) -> String {
        var text = "FHIR Resource (Decoded):\n"
        let sortedKeys = data.keys.sorted()
        
        for key in sortedKeys {
            let value = data[key]
            let displayName = getFHIRFieldDisplayName(key)
            text += "• \(displayName): "
            
            if let dict = value as? [String: Any] {
                text += "\n"
                let nestedText = formatFHIRDataForDisplay(dict)
                let indentedText = nestedText.components(separatedBy: "\n")
                    .map { "  \($0)" }
                    .joined(separator: "\n")
                text += indentedText
            } else if let array = value as? [Any] {
                text += "\n"
                for (index, item) in array.enumerated() {
                    if let itemDict = item as? [String: Any] {
                        text += "  [\(index + 1)]\n"
                        let nestedText = formatFHIRDataForDisplay(itemDict)
                        let indentedText = nestedText.components(separatedBy: "\n")
                            .map { "    \($0)" }
                            .joined(separator: "\n")
                        text += indentedText
                    } else {
                        text += "  [\(index + 1)] \(item)\n"
                    }
                }
            } else {
                text += "\(value)\n"
            }
        }
        
        return text
    }
    
    /// Convert FHIR field names to human-readable labels
    private func getFHIRFieldDisplayName(_ fieldName: String) -> String {
        switch fieldName.lowercased() {
        case "resourcetype": return "Resource Type"
        case "id": return "ID"
        case "status": return "Status"
        case "patient": return "Patient"
        case "recordeddate": return "Recorded Date"
        case "substance": return "Substance/Allergen"
        case "reaction": return "Reactions"
        case "onset": return "Onset Date"
        case "manifestation": return "Symptoms"
        case "severity": return "Severity"
        case "text": return "Description"
        case "display": return "Name"
        case "coding": return "Medical Codes"
        case "system": return "Code System"
        case "code": return "Code"
        case "reference": return "Reference"
        case "category": return "Category"
        case "clinicalstatus": return "Clinical Status"
        case "verificationstatus": return "Verification Status"
        case "type": return "Type"
        case "subject": return "Subject"
        case "encounter": return "Encounter"
        case "effectivedatetime": return "Effective Date"
        case "performer": return "Performer"
        case "valuequantity": return "Value"
        case "component": return "Components"
        case "interpretation": return "Interpretation"
        case "referencerange": return "Reference Range"
        default: return fieldName.capitalized
        }
    }
}
