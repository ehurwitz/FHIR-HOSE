//
//  RecordRowView.swift
//  FHIR-HOSE
//
//  Created by Eric Hurwitz on 12/3/24.
//

import SwiftUI

struct RecordRowView: View {
    let record: HealthRecord
    
    var body: some View {
        HStack {
            Image(systemName: record.type == .pdf ? "doc.fill" : "photo.fill")
                .foregroundColor(.blue)
            
            VStack(alignment: .leading) {
                Text(record.filename)
                    .font(.body)
                Text(record.date, style: .date)
                    .font(.caption)
                    .foregroundColor(.gray)
            }
            
            Spacer()
            
            if record.processed {
                Image(systemName: "checkmark.circle.fill")
                    .foregroundColor(.green)
            } else {
                Image(systemName: "clock.fill")
                    .foregroundColor(.orange)
            }
        }
        .padding(.vertical, 4)
    }
}
