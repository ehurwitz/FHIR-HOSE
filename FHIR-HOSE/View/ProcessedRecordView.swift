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

            if let fhir = record.fhirData {
                // Show raw JSON or pick out fields from the dictionary
                ScrollView {
                    Text(prettyPrintedJSON(fhir))
                        .font(.system(.body, design: .monospaced))
                        .padding()
                }
            } else {
                Text("No FHIR data available.")
            }
        }
        .padding()
    }
    
    /// Utility to pretty-print a dictionary as JSON
    func prettyPrintedJSON(_ dict: [String: Any]) -> String {
        if let data = try? JSONSerialization.data(withJSONObject: dict, options: [.prettyPrinted]),
           let str = String(data: data, encoding: .utf8) {
            return str
        }
        return "\(dict)"
    }
}

