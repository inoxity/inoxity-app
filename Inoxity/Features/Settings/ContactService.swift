import Foundation

struct ContactSubmission: Sendable {
    let studyCode: String
    let message: String
    let replyToEmail: String?
}

enum ContactServiceError: LocalizedError {
    case notConfigured
    case invalidResponse
    case server(String)

    var errorDescription: String? {
        switch self {
        case .notConfigured: "This feature isn't set up yet — email the study contact directly instead."
        case .invalidResponse: "Something went wrong sending your message. Please try again."
        case .server(let message): message
        }
    }
}

/// Relays a participant's message to the study's research team via the
/// dashboard's `/api/contact` route (inoxity-dashboard/src/app/api/contact/route.ts),
/// which emails the study's configured support contact. Deliberately writes
/// nothing to inoxity_backend — no message content is stored anywhere in
/// Inoxity's own infrastructure, only relayed through and discarded.
///
/// Configuration comes from INOXITY_CONTACT_ENDPOINT_URL /
/// INOXITY_CONTACT_SHARED_SECRET (see Config/Secrets.example.xcconfig),
/// mirroring how BackendEnvironment reads its own Info.plist-driven config
/// (see Backend/Environment/BackendEnvironment.swift). Both are blank by
/// default — that just disables the feature (`isAvailable == false`)
/// rather than crashing, since deploying the dashboard's Resend-backed
/// route is a separate step from shipping this app update.
struct ContactService: Sendable {
    private let endpointURL: URL?
    private let sharedSecret: String?
    private let session: URLSession

    var isAvailable: Bool { endpointURL != nil && sharedSecret != nil }

    init(bundle: Bundle = .main, session: URLSession = .shared) {
        let rawURL = (bundle.object(forInfoDictionaryKey: "INOXITY_CONTACT_ENDPOINT_URL") as? String)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let secret = (bundle.object(forInfoDictionaryKey: "INOXITY_CONTACT_SHARED_SECRET") as? String)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if let rawURL, !rawURL.isEmpty, let url = URL(string: rawURL), url.scheme == "https" {
            endpointURL = url.appendingPathComponent("api/contact")
        } else {
            endpointURL = nil
        }
        sharedSecret = (secret?.isEmpty == false) ? secret : nil
        self.session = session
    }

    func send(_ submission: ContactSubmission) async throws {
        guard let endpointURL, let sharedSecret else { throw ContactServiceError.notConfigured }
        var request = URLRequest(url: endpointURL)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(sharedSecret, forHTTPHeaderField: "x-contact-secret")
        request.httpBody = try JSONEncoder().encode(ContactRequestBody(
            studyCode: submission.studyCode, message: submission.message, replyToEmail: submission.replyToEmail))

        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw ContactServiceError.invalidResponse }
        guard (200..<300).contains(http.statusCode) else {
            let serverMessage = (try? JSONDecoder().decode(ContactErrorBody.self, from: data))?.error
            throw ContactServiceError.server(serverMessage ?? "Something went wrong sending your message. Please try again.")
        }
    }
}

private struct ContactRequestBody: Encodable {
    let studyCode: String
    let message: String
    let replyToEmail: String?
}

private struct ContactErrorBody: Decodable {
    let error: String
}
