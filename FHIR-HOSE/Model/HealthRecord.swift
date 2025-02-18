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
    
    enum RecordType {
        case pdf
        case image
    }
}
