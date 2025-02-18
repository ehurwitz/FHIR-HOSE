//
//  RecordDetailView.swift
//  FHIR-HOSE
//
//  Created by Eric Hurwitz on 12/3/24.
//

import SwiftUI

struct RecordDetailView: View {
    let record: HealthRecord
    
    var body: some View {
        VStack {
            // This is a placeholder for the actual record view
            // In the future, this will show processed FHIR data
            Group {
                if record.processed {
                    ProcessedRecordView()
                } else {
                    UnprocessedRecordView()
                }
            }
        }
        .navigationTitle(record.filename)
    }
}

struct ProcessedRecordView: View {
    var body: some View {
        VStack(spacing: 20) {
            Text("Processed Record")
                .font(.headline)
            
            // Placeholder for FHIR data
            VStack(alignment: .leading, spacing: 10) {
                RecordField(title: "Patient", value: "[Processed Patient Name]")
                RecordField(title: "Date of Service", value: "[Processed Date]")
                RecordField(title: "Provider", value: "[Processed Provider]")
                RecordField(title: "Diagnosis", value: "[Processed Diagnosis]")
            }
            .padding()
            .background(Color(.systemBackground))
            .cornerRadius(10)
            .shadow(radius: 1)
        }
        .padding()
    }
}
