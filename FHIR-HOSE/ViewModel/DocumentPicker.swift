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

import SwiftUI

extension HealthRecordStore {

    /// Process a PDF record via Charmonizer:
    ///  - Upload to `/conversions/documents`
    ///  - Poll for completion, get doc object
    ///  - Summarize with the FHIR JSON schema
    ///  - Poll for summary
    ///  - Store the final FHIR data
    func processPDFRecord(_ record: HealthRecord) {
        guard record.type == .pdf else { return }
        
        // Find the file's local URL in Documents:
        let filename = record.filename
        guard let pdfURL = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)
            .first?.appendingPathComponent(filename),
              FileManager.default.fileExists(atPath: pdfURL.path)
        else {
            print("Local PDF not found: \(filename)")
            return
        }

        // Run the pipeline on a background Task:
        Task {
            do {
                // 1) Upload
                let docObject = try await uploadPDF(to: pdfURL)

                // 2) Summarize with the FHIR schema
                let fhirDoc = try await summarizeFHIR(docObject: docObject)

                // 3) Parse out the FHIR from the final doc
                //    Typically, the summarizer places structured JSON in doc.annotations["summary"].
                //    With the "inlined-minimum-fhir.json.schema", you’ll get the fields inline.
                //    Here we just store it as a raw dictionary or JSON string for display.
                
                // (If you prefer a custom Swift struct, decode it.
                //  But for demonstration, we'll store as a raw dictionary.)
                
                let fhirDict = fhirDoc.annotations?["summary"] as? [String:Any]
                // Or you might do: JSONSerialization to store as Data, etc.

                // 4) Update record in main thread:
                await MainActor.run {
                    // Mark the record as processed:
                    if let idx = self.records.firstIndex(where: {$0.id == record.id}) {
                        self.records[idx].processed = true
                        self.records[idx].fhirData = fhirDict
                    }
                }
                
            } catch {
                print("Error processing PDF: \(error)")
                // handle error (show alert, etc)
            }
        }
    }

    // MARK: - Private Helper: upload PDF

    private func uploadPDF(to pdfURL: URL) async throws -> JSONDocument {
        // Adjust for your server’s address:
        let serverBase = "http://matt.might.net:5002"  // Example
        let baseUrlPrefix = "/charm/api/charmonizer/v1"

        let uploadEndpoint = "\(serverBase)\(baseUrlPrefix)/conversions/documents"

        // Prepare a multipart/form-data request in Swift concurrency style:
        // If you prefer older APIs, you can do manual URLRequest + boundary, etc.
        
        // We'll do it with URLSession, so we create the request with manual body.

        let pdfData = try Data(contentsOf: pdfURL)
        
        // Typically, you'd generate a boundary & form-data body yourself:
        let boundary = "----Boundary-\(UUID().uuidString)"
        var request = URLRequest(url: URL(string: uploadEndpoint)!)
        request.httpMethod = "POST"
        
        let formData = buildMultipartFormData(
            fileData: pdfData,
            fieldName: "file",
            filename: pdfURL.lastPathComponent,
            mimeType: "application/pdf",
            fields: [
                // Additional form fields:
                "model": "gpt-4o",
                "ocr_threshold": "0.7",
                "page_numbering": "true"
                // etc, as needed
            ],
            boundary: boundary
        )
        
        request.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")
        request.httpBody = formData

        // Send:
        let (data, response) = try await URLSession.shared.data(for: request)
        
        guard let httpResponse = response as? HTTPURLResponse,
              httpResponse.statusCode == 200 else {
            let bodyText = String(data: data, encoding: .utf8) ?? "(no body)"
            throw URLError(.badServerResponse, userInfo: ["body": bodyText])
        }

        // Parse JSON => { job_id: String }
        let jobReply = try JSONDecoder().decode(JobIDReply.self, from: data)
        guard let jobId = jobReply.job_id else {
            throw URLError(.cannotParseResponse)
        }

        // Poll for status
        let statusUrl = "\(serverBase)\(baseUrlPrefix)/conversions/documents/\(jobId)"
        let resultUrl = "\(statusUrl)/result"

        while true {
            try await Task.sleep(nanoseconds: 3_000_000_000) // poll every 3s
            let statusData = try await simpleGet(urlString: statusUrl)
            // e.g. { status: "processing", pages_total: N, pages_converted: M }
            // If status=error => throw
            // If status=complete => break

            let statusObj = try JSONDecoder().decode(DocConversionStatus.self, from: statusData)
            if statusObj.status == "complete" {
                break
            } else if statusObj.status == "error" {
                throw NSError(domain: "Charmonizer", code: 1, userInfo: [NSLocalizedDescriptionKey: statusObj.error ?? "Unknown error"])
            }
        }

        // Now fetch final doc object:
        let finalData = try await simpleGet(urlString: resultUrl)
        let docObject = try JSONDecoder().decode(JSONDocument.self, from: finalData)
        return docObject
    }

    // MARK: - Private Helper: Summarize with FHIR

    private func summarizeFHIR(docObject: JSONDocument) async throws -> JSONDocument {
        let serverBase = "http://matt.might.net:5002"
        let baseUrlPrefix = "/charm/api/charmonizer/v1"
        let summaryEndpoint = "\(serverBase)\(baseUrlPrefix)/summaries"

        
        // Load and convert the FHIR schema
        let fhirSchema = loadFHIRSchema()
        let convertedSchema = convertToCodableValue(fhirSchema)

        // Prepare the summarize request
        let summarizeRequest = SummarizeRequest(
            document: docObject,
            method: "full",
            model: "gpt-4o",
            json_schema: convertedSchema
        )

        // Encode the request into JSON
        let encoded = try JSONEncoder().encode(summarizeRequest)

        // Create and configure the HTTP request
        var request = URLRequest(url: URL(string: summaryEndpoint)!)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = encoded
        
        // Send the request
        let (data, response) = try await URLSession.shared.data(for: request)
        
        // Check for HTTP 202 status
        guard let httpResponse = response as? HTTPURLResponse, httpResponse.statusCode == 202 else {
            let bodyText = String(data: data, encoding: .utf8) ?? "(no body)"
            throw URLError(.badServerResponse, userInfo: ["body": bodyText])
        }

        // Decode the job ID from the response
        let jobReply = try JSONDecoder().decode(JobIDReply.self, from: data)
        guard let jobId = jobReply.job_id else {
            throw URLError(.cannotParseResponse)
        }

        // Polling for job completion
        let statusUrl = "\(summaryEndpoint)/\(jobId)"
        let resultUrl = "\(statusUrl)/result"
        
        while true {
            try await Task.sleep(nanoseconds: 3_000_000_000)  // Wait 3 seconds before polling

            let statusData = try await simpleGet(urlString: statusUrl)
            let sumStatusObj = try JSONDecoder().decode(SummaryStatus.self, from: statusData)
            
            switch sumStatusObj.status {
            case "complete":
                break
            case "error":
                throw NSError(domain: "CharmonizerSummary", code: 1, userInfo: [NSLocalizedDescriptionKey: sumStatusObj.error ?? "Unknown error"])
            default:
                continue
            }
        }

        // Fetch and return the final summarized FHIR document
        let finalData = try await simpleGet(urlString: resultUrl)
        let fhirDoc = try JSONDecoder().decode(JSONDocument.self, from: finalData)
        
        return fhirDoc
    }


    // MARK: - Utility: GET request

    private func simpleGet(urlString: String) async throws -> Data {
        guard let url = URL(string: urlString) else {
            throw URLError(.badURL)
        }
        let (data, response) = try await URLSession.shared.data(from: url)
        guard let httpResponse = response as? HTTPURLResponse, httpResponse.statusCode == 200 || httpResponse.statusCode == 202 else {
            throw URLError(.badServerResponse)
        }
        return data
    }

    // MARK: - Utility: build multipart form data

    private func buildMultipartFormData(
        fileData: Data,
        fieldName: String,
        filename: String,
        mimeType: String,
        fields: [String:String],
        boundary: String
    ) -> Data {
        var body = Data()

        // Add extra form fields:
        for (k,v) in fields {
            body.append("--\(boundary)\r\n".data(using: .utf8)!)
            body.append("Content-Disposition: form-data; name=\"\(k)\"\r\n\r\n".data(using: .utf8)!)
            body.append("\(v)\r\n".data(using: .utf8)!)
        }

        // Add file data
        body.append("--\(boundary)\r\n".data(using: .utf8)!)
        body.append("Content-Disposition: form-data; name=\"\(fieldName)\"; filename=\"\(filename)\"\r\n".data(using: .utf8)!)
        body.append("Content-Type: \(mimeType)\r\n\r\n".data(using: .utf8)!)
        body.append(fileData)
        body.append("\r\n".data(using: .utf8)!)
        
        // Close
        body.append("--\(boundary)--\r\n".data(using: .utf8)!)
        
        return body
    }

    // MARK: - Schema

    private func loadFHIRSchema() -> [String:Any] {
        // This is your inlined-minimum-fhir.json.schema turned into a Swift dictionary.
        // For brevity, we won’t paste the entire schema.  Just parse from a local JSON file
        // or embed a subset. Example:

        // Suppose you stored the schema in your app bundle as "inlined-minimum-fhir.json":
        if let url = Bundle.main.url(forResource: "inlined-minimum-fhir", withExtension: "json") {
            if let data = try? Data(contentsOf: url) {
                if let obj = try? JSONSerialization.jsonObject(with: data, options: []),
                   let dict = obj as? [String:Any] {
                    return dict
                }
            }
        }
        return [:] // fallback
    }
}

// Minimal Swift structs for decoding the job replies/status:

struct JobIDReply: Decodable {
    let job_id: String?
}

struct DocConversionStatus: Decodable {
    let status: String
    let error: String?
    let pages_total: Int?
    let pages_converted: Int?
}

struct SummaryStatus: Decodable {
    let status: String
    let error: String?
    let chunks_total: Int?
    let chunks_completed: Int?
}

/// The doc object schema from your server docs, as a raw Swift structure:
/// For brevity, we only store a few fields.  Expand as needed.
struct JSONDocument: Codable {
    var id: String
    var content: String?
    var annotations: [String:AnyCodable]?
    var metadata: [String:AnyCodable]?
    var chunks: [String:[JSONDocument]]? // chunk group name -> array of child docs
    
    // Because `annotations` and `metadata` can contain arbitrary JSON,
    // you can store them with an `AnyCodable` or use a custom approach.
}

/// Summarize request
struct SummarizeRequest: Codable {
    let document: JSONDocument
    let method: String      // "full" or "map" etc
    let model: String       // "gpt-4o"
    let json_schema: [String: CodableValue]?
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




/// A simplistic "any" container for decoding arbitrary JSON
/// (Alternatively, use JSONSerialization manually.)
struct AnyCodable: Codable {
    let value: Any
    
    init(_ value: Any) {
        self.value = value
    }
    
    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if let obj = try? container.decode(String.self) {
            self.value = obj
        } else if let num = try? container.decode(Double.self) {
            self.value = num
        } else if let boo = try? container.decode(Bool.self) {
            self.value = boo
        } else if let nestedDict = try? container.decode([String:AnyCodable].self) {
            self.value = nestedDict.mapValues { $0.value }
        } else if let nestedArr = try? container.decode([AnyCodable].self) {
            self.value = nestedArr.map { $0.value }
        } else if container.decodeNil() {
            self.value = NSNull()
        } else {
            throw DecodingError.dataCorruptedError(in: container, debugDescription: "Unsupported JSON type")
        }
    }

    func encode(to encoder: Encoder) throws {
        // for this example we won't handle encode thoroughly
        // but you could implement it if you want symmetrical usage
        var container = encoder.singleValueContainer()
        if let s = value as? String {
            try container.encode(s)
        } else if let d = value as? Double {
            try container.encode(d)
        } else if let b = value as? Bool {
            try container.encode(b)
        } else if let dict = value as? [String:Any] {
            let converted = dict.mapValues { AnyCodable($0) }
            try container.encode(converted)
        } else if let arr = value as? [Any] {
            let converted = arr.map { AnyCodable($0) }
            try container.encode(converted)
        } else if value is NSNull {
            try container.encodeNil()
        } else {
            // fallback
            throw EncodingError.invalidValue(value, .init(codingPath: container.codingPath, debugDescription: "Unsupported type"))
        }
    }
}
