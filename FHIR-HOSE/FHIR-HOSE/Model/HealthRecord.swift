//
//  HealthRecord.swift
//  FHIR-HOSE
//
//  Created by Eric Hurwitz on 12/3/24.
//

import Foundation

struct HealthRecord: Identifiable {
    let id = UUID()
    let filename: String
    let type: RecordType
    var processed: Bool = false
    var date: Date = Date()

    /// NEW: We store the final FHIR data (if any) in a dictionary after processing.
    var fhirData: [String: Any]? = nil

    enum RecordType {
        case pdf
        case image
    }
}
