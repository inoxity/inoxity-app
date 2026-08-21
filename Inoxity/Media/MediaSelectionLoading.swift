import Foundation

protocol MediaSelectionLoading: Sendable {
    func loadSelection() async throws -> MediaSelection
}
