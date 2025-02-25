//
//  RecordsListView.swift
//  FHIR-HOSE
//
//  Created by Eric Hurwitz on 12/3/24.
//

import SwiftUI

struct RecordsListView: View {
    @ObservedObject var recordStore: HealthRecordStore
    
    var body: some View {
        List {
            ForEach(recordStore.records) { record in
                NavigationLink(destination: ProcessedRecordView(record: record)) {
                    RecordRowView(record: record)
                }
            }
        }
        .listStyle(InsetGroupedListStyle())
    }
}
