//
//  HealthRecordStore.swift
//  FHIR-HOSE
//
//  Created by Eric Hurwitz on 12/3/24.
//

import Foundation
import SwiftUI
import OSLog


/// Observable store for HealthRecords.
/// Now includes methods for processing PDFs via Charmonizer at http://matt.might.net:5002
class HealthRecordStore: ObservableObject {

    @Published var records: [HealthRecord] = []

    /// Add a new record manually
    func addRecord(filename: String, type: HealthRecord.RecordType) {
        let record = HealthRecord(filename: filename, type: type)
        records.append(record)
    }

    // MARK: - PDF → Charmonizer → Summarize to FHIR

    /// Process a PDF record via Charmonizer:
    ///  1) Upload to /conversions/documents at http://matt.might.net:5002
    ///  2) Poll for completion
    ///  3) Summarize with FHIR schema, poll again
    ///  4) Store final FHIR data in record
    ///
    /// This will run asynchronously in a Task.
    func processPDFRecord(_ record: HealthRecord) {
        guard record.type == .pdf else { return }
        logger.log("Starting processPDFRecord for \(record.filename)")

        // Find local file
        guard let docsURL = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first else {
            logger.error("Could not find documentDirectory for userDomainMask.")
            return
        }
        let pdfURL = docsURL.appendingPathComponent(record.filename)
        guard FileManager.default.fileExists(atPath: pdfURL.path) else {
            logger.error("PDF file not found at path: \(pdfURL.path, privacy: .public)")
            return
        }

        Task.detached(priority: .background) {
            do {
                self.logger.log("uploadPDF() → \(pdfURL.absoluteString, privacy: .public)")
                let docObject = try await self.uploadPDF(to: pdfURL)
                self.logger.log("uploadPDF() complete for \(record.filename). Summarizing to FHIR next.")

                let fhirDoc = try await self.summarizeFHIR(docObject: docObject)
                self.logger.log("FHIR summarization complete for \(record.filename). Updating store...")

                // Extract the final summary from fhirDoc.annotations?["summary"]
                var fhirDict: [String: Any]? = nil
                if let ann = fhirDoc.annotations,
                   let summaryVal = ann["summary"]?.value as? [String: Any] {
                    fhirDict = summaryVal
                }

                // Update the record on the MainActor
                await MainActor.run {
                    if let idx = self.records.firstIndex(where: { $0.id == record.id }) {
                        self.records[idx].processed = true
                        self.records[idx].fhirData = fhirDict
                    }
                }

                self.logger.log("Record \(record.filename) successfully processed and updated.")

            } catch {
                self.logger.error("Error while processing \(record.filename): \(error.localizedDescription, privacy: .public)")
            }
        }
    }

    // MARK: - Private Helpers

    private let logger = Logger(subsystem: "com.example.fhirhose", category: "Charmonizer")
    
    private func debugDocObject(_ doc: JSONDocument) -> String {
        // Convert JSONDocument to JSON text, so we can see all fields (content, chunks, etc).
        // We can do a 'catch' if needed:
        do {
            let encoded = try JSONEncoder().encode(doc)
            return String(data: encoded, encoding: .utf8) ?? "(encoding failure)"
        } catch {
            return "Could not encode docObject: \(error.localizedDescription)"
        }
    }

    /// Upload the PDF to Charmonizer at http://matt.might.net:5002, poll, then return final doc object
    private func uploadPDF(to pdfURL: URL) async throws -> JSONDocument {
        guard let config = loadServerConfig() else {
            // handle error, e.g. throw or return
            throw URLError(.badURL)
        }

        // Now build endpoints
        let uploadEndpoint = "\(config.serverBase)\(config.baseUrlPrefix)/conversions/documents"

        
        let pdfData = try Data(contentsOf: pdfURL)
        let boundary = "----Boundary-\(UUID().uuidString)"

        var request = URLRequest(url: URL(string: uploadEndpoint)!)
        request.httpMethod = "POST"
        request.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")

        let formData = buildMultipartFormData(
            fileData: pdfData,
            fieldName: "file",
            filename: pdfURL.lastPathComponent,
            mimeType: "application/pdf",
            fields: [
                "model": "gpt-4o",
                "ocr_threshold": "0.7",
                "page_numbering": "true"
            ],
            boundary: boundary
        )
        request.httpBody = formData

        logger.log("POST /conversions/documents → uploading \(pdfData.count) bytes")

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse,
              httpResponse.statusCode == 200 else {
            let bodyText = String(data: data, encoding: .utf8) ?? "(no body)"
            logger.error("Upload response was not 200: \(bodyText, privacy: .public)")
            throw URLError(.badServerResponse)
        }

        let jobReply = try JSONDecoder().decode(JobIDReply.self, from: data)
        guard let jobId = jobReply.job_id else {
            logger.error("No job_id in response from /conversions/documents.")
            throw URLError(.cannotParseResponse)
        }

        // Poll:
        let statusUrl = "\(config.serverBase)\(config.baseUrlPrefix)/conversions/documents/\(jobId)"
        let resultUrl = "\(statusUrl)/result"

        while true {
            try await Task.sleep(nanoseconds: 3_000_000_000)
            let statusData = try await simpleGet(urlString: statusUrl)
            let statusObj = try JSONDecoder().decode(DocConversionStatus.self, from: statusData)

            if statusObj.status == "complete" {
                logger.log("Document conversion job \(jobId) is complete.")
                break
            } else if statusObj.status == "error" {
                let msg = statusObj.error ?? "Unknown error"
                logger.error("Document conversion job \(jobId) error: \(msg, privacy: .public)")
                throw NSError(domain: "Charmonizer", code: 1, userInfo: [NSLocalizedDescriptionKey: msg])
            } else {
                logger.log("Polling job \(jobId): pagesConverted=\(statusObj.pages_converted ?? 0), total=\(statusObj.pages_total ?? 0)")
            }
        }

        // Retrieve final doc
        logger.log("Fetching final doc object for job \(jobId)")
        let finalData = try await simpleGet(urlString: resultUrl)
        let docObject = try JSONDecoder().decode(JSONDocument.self, from: finalData)
        
        // Right after conversion completes, before summarizing:
        self.logger.log("Converted docObject:\n\(self.debugDocObject(docObject))")

        return docObject
    }

    /// Summarize doc object with the FHIR JSON schema
    private func summarizeFHIR(docObject: JSONDocument) async throws -> JSONDocument {
        guard let config = loadServerConfig() else {
            // handle error, e.g. throw or return
            throw URLError(.badURL)
        }
        let endpoint = "\(config.serverBase)\(config.baseUrlPrefix)/summaries"

        // Load the JSON schema from your app bundle or inline
        let fhirSchema = loadFHIRSchema()
        
        // Print out the fhirSchema
        logger.log("FHIR Schema: \(fhirSchema, privacy: .public)")

        let summaryReq = SummarizeRequest(
            document: docObject,
            method: "full",
            model: "gpt-4o",
            json_schema: fhirSchema
        )

        let encoded = try JSONEncoder().encode(summaryReq)
        if let jsonText = String(data: encoded, encoding: .utf8) {
            self.logger.log("SummarizeRequest JSON:\n\(jsonText, privacy: .public)")
        }

        var request = URLRequest(url: URL(string: endpoint)!)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = encoded

        logger.log("POST /summaries to summarize doc ID \(docObject.id, privacy: .public) with FHIR schema.")
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse,
              httpResponse.statusCode == 202 else {
            let bodyText = String(data: data, encoding: .utf8) ?? "(no body)"
            logger.error("Summaries request not accepted (202). Got: \(bodyText, privacy: .public)")
            throw URLError(.badServerResponse)
        }

        let jobReply = try JSONDecoder().decode(JobIDReply.self, from: data)
        guard let jobId = jobReply.job_id else {
            logger.error("No job_id in Summaries response.")
            throw URLError(.cannotParseResponse)
        }

        let statusUrl = "\(endpoint)/\(jobId)"
        let resultUrl = "\(statusUrl)/result"

        // poll
        while true {
            try await Task.sleep(nanoseconds: 3_000_000_000)
            let stData = try await simpleGet(urlString: statusUrl)
            let sumStatus = try JSONDecoder().decode(SummaryStatus.self, from: stData)

            if sumStatus.status == "complete" {
                logger.log("Summarization job \(jobId) completed successfully.")
                break
            } else if sumStatus.status == "error" {
                let msg = sumStatus.error ?? "Unknown error"
                logger.error("Summarization job \(jobId) error: \(msg, privacy: .public)")
                throw NSError(domain: "CharmonizerSummary", code: 1, userInfo: [NSLocalizedDescriptionKey: msg])
            } else {
                logger.log("Polling summarization job \(jobId): chunksCompleted=\(sumStatus.chunks_completed ?? 0)/\(sumStatus.chunks_total ?? 0)")
            }
        }

        logger.log("Fetching final summarized doc for job \(jobId).")
        let finalData = try await simpleGet(urlString: resultUrl)
        let fhirDoc = try JSONDecoder().decode(JSONDocument.self, from: finalData)

        // Right after summarization completes, before updating the record:
        self.logger.log("Final fhirDoc:\n\(self.debugDocObject(fhirDoc))")
        
        return fhirDoc
    }
    
    /// Load your FHIR JSON schema from the bundle or inline.
    /// This is just an example placeholder — adapt to your actual approach.
    /// This approach didn't work because there was an error that converted false to 0 in the JSON schema during round-trip.
    /*
    private func loadFHIRSchema() -> [String:Any] {
        // For brevity, we’ll assume you have "inlined-minimum-fhir.json" in your app bundle
        if let url = Bundle.main.url(forResource: "inlined-minimum-fhir", withExtension: "json") {
            if let data = try? Data(contentsOf: url),
               let obj = try? JSONSerialization.jsonObject(with: data),
               let dict = obj as? [String:Any] {
                return dict
            }
        }
        logger.warning("FHIR schema not found in bundle. Returning empty dictionary.")
        return [:]
    }
    */
    
    private func loadServerConfig() -> ServerConfig? {
        guard let url = Bundle.main.url(forResource: "server-config", withExtension: "json") else {
            // Could log a warning or return nil
            return nil
        }

        do {
            let data = try Data(contentsOf: url)
            let config = try JSONDecoder().decode(ServerConfig.self, from: data)
            return config
        } catch {
            // Log or handle the error
            print("Error loading or decoding server-config.json:", error)
            return nil
        }
    }

    
    private func loadFHIRSchema() -> String {
        guard let url = Bundle.main.url(
            forResource: "inlined-minimum-fhir",
            withExtension: "json"
        ) else {
            logger.warning("No FHIR schema file in bundle.")
            return ""
        }
        do {
            let rawText = try String(contentsOf: url, encoding: .utf8)
            return rawText
        } catch {
            logger.error("Failed to load schema file: \(error.localizedDescription)")
            return ""
        }
    }


    /// Basic GET request helper
    private func simpleGet(urlString: String) async throws -> Data {
        guard let url = URL(string: urlString) else {
            throw URLError(.badURL)
        }
        let (data, response) = try await URLSession.shared.data(from: url)
        guard let httpResponse = response as? HTTPURLResponse,
              (200...299).contains(httpResponse.statusCode) else {
            throw URLError(.badServerResponse)
        }
        return data
    }

    /// Helper to build multipart/form-data
    private func buildMultipartFormData(
        fileData: Data,
        fieldName: String,
        filename: String,
        mimeType: String,
        fields: [String:String],
        boundary: String
    ) -> Data {
        var body = Data()

        // Extra fields
        for (k,v) in fields {
            body.append("--\(boundary)\r\n".data(using: .utf8)!)
            body.append("Content-Disposition: form-data; name=\"\(k)\"\r\n\r\n".data(using: .utf8)!)
            body.append("\(v)\r\n".data(using: .utf8)!)
        }

        // File part
        body.append("--\(boundary)\r\n".data(using: .utf8)!)
        body.append("Content-Disposition: form-data; name=\"\(fieldName)\"; filename=\"\(filename)\"\r\n".data(using: .utf8)!)
        body.append("Content-Type: \(mimeType)\r\n\r\n".data(using: .utf8)!)
        body.append(fileData)
        body.append("\r\n".data(using: .utf8)!)

        // Close
        body.append("--\(boundary)--\r\n".data(using: .utf8)!)
        return body
    }
}
