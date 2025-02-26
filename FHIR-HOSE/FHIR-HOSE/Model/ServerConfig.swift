//
//  ServerConfig.swift
//  FHIR-HOSE
//
//  Created by Matthew Might on 2/26/25.
//


import Foundation

struct ServerConfig: Codable {
    let serverBase: String
    let baseUrlPrefix: String
    // Add other fields if you like (API key, etc.).
}
