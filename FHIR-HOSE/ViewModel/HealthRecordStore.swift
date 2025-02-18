//
//  HealthRecordStore.swift
//  FHIR-HOSE
//
//  Created by Eric Hurwitz on 12/3/24.
//

import Foundation

class HealthRecordStore: ObservableObject {
    @Published var records: [HealthRecord] = []
    
    func addRecord(filename: String, type: HealthRecord.RecordType) {
        let record = HealthRecord(filename: filename, type: type)
        records.append(record)
    }
}
