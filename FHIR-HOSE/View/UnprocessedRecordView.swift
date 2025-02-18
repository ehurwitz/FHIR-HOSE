//
//  UnprocessedRecordView.swift
//  FHIR-HOSE
//
//  Created by Eric Hurwitz on 12/3/24.
//

import SwiftUI

struct UnprocessedRecordView: View {
    var body: some View {
        VStack(spacing: 20) {
            Image(systemName: "clock.fill")
                .font(.system(size: 50))
                .foregroundColor(.orange)
            
            Text("Processing...")
                .font(.headline)
            
            Text("This record is waiting to be processed. Check back soon.")
                .font(.subheadline)
                .foregroundColor(.gray)
                .multilineTextAlignment(.center)
        }
        .padding()
    }
}

