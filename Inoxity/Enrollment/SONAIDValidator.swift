import Foundation

enum SONAIDValidationResult: Equatable, Sendable {
    case valid(String)
    case empty
    case containsInvalidCharacters
    case tooLong

    var isValid: Bool {
        if case .valid = self { return true }
        return false
    }

    var message: String? {
        switch self {
        case .valid: nil
        case .empty: "Enter your SONA ID."
        case .containsInvalidCharacters: "SONA ID can contain numbers only."
        case .tooLong: "SONA ID must be six digits or fewer."
        }
    }
}

struct SONAIDValidator: Sendable {
    static let configuredPattern = "^[0-9]{1,6}$"

    func validate(_ value: String) -> SONAIDValidationResult {
        guard !value.isEmpty else { return .empty }
        guard value.count <= 6 else { return .tooLong }
        guard value.unicodeScalars.allSatisfy({ (48...57).contains($0.value) }) else {
            return .containsInvalidCharacters
        }
        return .valid(value)
    }

    static func applies(to configuration: ParticipantIDConfiguration) -> Bool {
        configuration.allowedPattern == configuredPattern && configuration.maximumLength == 6
    }
}

enum ParticipantIDValidationResult: Equatable, Sendable {
    case valid(String)
    case invalid(String)

    var value: String? {
        if case .valid(let value) = self { return value }
        return nil
    }
}

struct ParticipantIDValidator: Sendable {
    private let sona = SONAIDValidator()

    func validate(_ value: String, configuration: ParticipantIDConfiguration) -> ParticipantIDValidationResult {
        if SONAIDValidator.applies(to: configuration) {
            switch sona.validate(value) {
            case .valid(let validated): return .valid(validated)
            case .empty: return .invalid("Enter your SONA ID.")
            case .containsInvalidCharacters: return .invalid("SONA ID can contain numbers only.")
            case .tooLong: return .invalid("SONA ID must be six digits or fewer.")
            }
        }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        if !configuration.required && trimmed.isEmpty { return .valid("") }
        guard (configuration.minimumLength...configuration.maximumLength).contains(trimmed.count) else {
            return .invalid("Enter a valid \(configuration.label.lowercased()).")
        }
        if let pattern = configuration.allowedPattern,
           trimmed.range(of: pattern, options: .regularExpression) == nil {
            return .invalid("Enter a valid \(configuration.label.lowercased()).")
        }
        return .valid(trimmed)
    }
}
