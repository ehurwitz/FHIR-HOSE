//
//  RecordFieldView.swift
//  FHIR-HOSE
//
//  Created by Eric Hurwitz on 12/3/24.
//

import SwiftUI

struct RecordField: View {
    let title: String
    let value: String
    
    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title)
                .font(.caption)
                .foregroundColor(.gray)
            Text(value)
                .font(.body)
        }
    }
}

