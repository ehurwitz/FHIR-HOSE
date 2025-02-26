//
//  ProcessedRecordView.swift
//  FHIR-HOSE
//
//  Created by Eric Hurwitz on 2/24/25.
//

import SwiftUI

struct ProcessedRecordView: View {
    let record: HealthRecord

    var body: some View {
        VStack(spacing: 20) {
            Text("Processed Record")
                .font(.headline)
            
            // If we have FHIR data, display it
            if let fhir = record.fhirData {
                ScrollView {
                    Text(prettyPrintedJSON(fhir))
                        .font(.system(.body, design: .monospaced))
                        .padding()
                }
            } else {
                Text("No FHIR data available.")
                    .foregroundColor(.secondary)
            }
        }
        .padding()
    }

    /// Utility to pretty-print a dictionary as JSON
    func prettyPrintedJSON(_ dict: [String: Any]) -> String {
        guard let data = try? JSONSerialization.data(withJSONObject: dict, options: [.prettyPrinted]),
              let string = String(data: data, encoding: .utf8) else {
            return "\(dict)"
        }
        return string
    }
}
