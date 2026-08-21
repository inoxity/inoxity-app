import Foundation

@MainActor
final class UserDefaultsWithdrawalEventStore: WithdrawalEventPersisting {
    static let key = "withdrawal.events.v1"
    private let defaults: UserDefaults
    private let encoder: JSONEncoder
    private let decoder: JSONDecoder

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        encoder = JSONEncoder(); encoder.dateEncodingStrategy = .iso8601
        decoder = JSONDecoder(); decoder.dateDecodingStrategy = .iso8601
    }

    func events(for studyID: String) throws -> [PendingWithdrawalEvent] {
        try envelope().eventsByStudyID[studyID] ?? []
    }

    func allEvents() throws -> [PendingWithdrawalEvent] { try envelope().eventsByStudyID.values.flatMap { $0 } }

    func save(_ event: PendingWithdrawalEvent) throws {
        var value = try envelope()
        var events = value.eventsByStudyID[event.studyID] ?? []
        guard !events.contains(where: { $0.id == event.id }) else { return }
        events.append(event); value.eventsByStudyID[event.studyID] = events
        defaults.set(try encoder.encode(value), forKey: Self.key)
    }


    func update(_ event: PendingWithdrawalEvent) throws {
        var value = try envelope(); var events = value.eventsByStudyID[event.studyID] ?? []
        guard let index = events.firstIndex(where: { $0.id == event.id }) else { try save(event); return }
        events[index] = event; value.eventsByStudyID[event.studyID] = events
        defaults.set(try encoder.encode(value), forKey: Self.key)
    }

    func remove(eventID: String, studyID: String) {
        guard var value = try? envelope() else { return }
        value.eventsByStudyID[studyID]?.removeAll { $0.id == eventID }
        if let data = try? encoder.encode(value) { defaults.set(data, forKey: Self.key) }
    }

    private func envelope() throws -> WithdrawalEventEnvelope {
        guard let data = defaults.data(forKey: Self.key) else {
            return .init(persistenceVersion: WithdrawalEventEnvelope.currentVersion, eventsByStudyID: [:])
        }
        let value: WithdrawalEventEnvelope
        do { value = try decoder.decode(WithdrawalEventEnvelope.self, from: data) }
        catch { throw WithdrawalEventPersistenceError.corruptData }
        guard (1...WithdrawalEventEnvelope.currentVersion).contains(value.persistenceVersion) else {
            throw WithdrawalEventPersistenceError.unsupportedVersion(value.persistenceVersion)
        }
        if value.persistenceVersion < WithdrawalEventEnvelope.currentVersion {
            let migrated = WithdrawalEventEnvelope(persistenceVersion: WithdrawalEventEnvelope.currentVersion, eventsByStudyID: value.eventsByStudyID)
            defaults.set(try encoder.encode(migrated), forKey: Self.key)
            return migrated
        }
        return value
    }
}
