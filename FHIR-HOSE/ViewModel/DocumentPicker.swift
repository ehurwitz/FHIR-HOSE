//
//  DocumentPicker.swift
//  FHIR-HOSE
//
//  Created by Eric Hurwitz on 12/3/24.
//

import Foundation
import SwiftUI
import UniformTypeIdentifiers

struct DocumentPicker: UIViewControllerRepresentable {
    @ObservedObject var recordStore: HealthRecordStore
    
    func makeUIViewController(context: Context) -> UIDocumentPickerViewController {
        let picker = UIDocumentPickerViewController(forOpeningContentTypes: [UTType.pdf])
        picker.delegate = context.coordinator
        return picker
    }
    
    func updateUIViewController(_ uiViewController: UIDocumentPickerViewController, context: Context) {}
    
    func makeCoordinator() -> Coordinator {
        Coordinator(self)
    }
    
    class Coordinator: NSObject, UIDocumentPickerDelegate {
        let parent: DocumentPicker
        
        init(_ parent: DocumentPicker) {
            self.parent = parent
        }
        
        func documentPicker(_ controller: UIDocumentPickerViewController, didPickDocumentsAt urls: [URL]) {
            guard let url = urls.first else { return }
            let filename = url.lastPathComponent

            // Copy it to the app’s local Documents directory...
            if let destinationURL = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first?.appendingPathComponent(filename) {
                try? FileManager.default.copyItem(at: url, to: destinationURL)
                
                DispatchQueue.main.async {
                    let newRecord = HealthRecord(filename: filename, type: .pdf)
                    self.parent.recordStore.records.append(newRecord)
                    
                    // Immediately start processing in the background:
                    self.parent.recordStore.processPDFRecord(newRecord)
                }
            }
        }

    }
}





enum CodableValue: Codable {
    case string(String)
    case int(Int)
    case double(Double)
    case bool(Bool)
    case dictionary([String: CodableValue])
    case array([CodableValue])
    case null

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if let string = try? container.decode(String.self) {
            self = .string(string)
        } else if let int = try? container.decode(Int.self) {
            self = .int(int)
        } else if let double = try? container.decode(Double.self) {
            self = .double(double)
        } else if let bool = try? container.decode(Bool.self) {
            self = .bool(bool)
        } else if let dictionary = try? container.decode([String: CodableValue].self) {
            self = .dictionary(dictionary)
        } else if let array = try? container.decode([CodableValue].self) {
            self = .array(array)
        } else if container.decodeNil() {
            self = .null
        } else {
            throw DecodingError.dataCorruptedError(in: container, debugDescription: "Unsupported type")
        }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .string(let value):
            try container.encode(value)
        case .int(let value):
            try container.encode(value)
        case .double(let value):
            try container.encode(value)
        case .bool(let value):
            try container.encode(value)
        case .dictionary(let value):
            try container.encode(value)
        case .array(let value):
            try container.encode(value)
        case .null:
            try container.encodeNil()
        }
    }
}
func convertToCodableValue(_ dictionary: [String: Any]) -> [String: CodableValue] {
    var convertedDict: [String: CodableValue] = [:]
    
    for (key, value) in dictionary {
        convertedDict[key] = CodableValue(fromAny: value)
    }
    
    return convertedDict
}
extension CodableValue {
    init(fromAny value: Any) {
        if let stringValue = value as? String {
            self = .string(stringValue)
        } else if let intValue = value as? Int {
            self = .int(intValue)
        } else if let doubleValue = value as? Double {
            self = .double(doubleValue)
        } else if let boolValue = value as? Bool {
            self = .bool(boolValue)
        } else if let dictValue = value as? [String: Any] {
            self = .dictionary(convertToCodableValue(dictValue))
        } else if let arrayValue = value as? [Any] {
            self = .array(arrayValue.map { CodableValue(fromAny: $0) })
        } else {
            self = .null
        }
    }
}




