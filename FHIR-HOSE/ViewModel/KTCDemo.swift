//
//  KTCDemo.swift
//  FHIR-HOSE
//
//  Created by Claude Code on 1/27/26.
//

import Foundation
import OSLog
import UIKit

@MainActor
final class KTCDemo: ObservableObject {
    private let logger = Logger(subsystem: "com.fhirhose.app", category: "KTC")

    enum Phase {
        case landing
        case scanning
        case analyzing
        case editing
        case error(String)
    }

    @Published var phase: Phase = .landing
    @Published var pages: [UIImage] = []
}
