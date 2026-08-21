import Foundation
import os

protocol BackendLogging: Sendable { func record(category: String, outcome: String, failure: BackendFailureCategory?) }

struct SanitizedLogger: BackendLogging, Sendable {
    private let logger = Logger(subsystem: "org.cogcommscience.Inoxity", category: "Backend")
    func record(category: String, outcome: String, failure: BackendFailureCategory? = nil) {
        logger.info("operation=\(category, privacy: .public) outcome=\(outcome, privacy: .public) failure=\(failure?.rawValue ?? "none", privacy: .public)")
    }
}
