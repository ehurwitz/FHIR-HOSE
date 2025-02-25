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
                    ProcessedRecordView(record: record)
                } else {
                    UnprocessedRecordView()
                }
            }
        }
        .navigationTitle(record.filename)
    }
}


