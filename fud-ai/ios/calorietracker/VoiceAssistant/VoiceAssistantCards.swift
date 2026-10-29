import Foundation
import Observation
import UIKit

/// A card the assistant shows while it works: a draft to review, a change
/// waiting for the user's yes, an Undo for a change it just made, or a notice.
struct VoiceAssistantCard: Identifiable {
    enum Content {
        case draft(Draft)
        case confirmation(Confirmation)
        case undo(Undo)
        case notice(Notice)
    }

    struct Draft {
        let draftID: String
        let isWorkout: Bool
        let title: String
        /// One line per item, e.g. "Rice · 1 cup · 205 kcal".
        let lines: [String]
        let calories: Int?
        /// "30P · 40C · 10F" for food.
        let macros: String?
        let thumbnail: UIImage?
        var isLogged = false
    }

    struct Confirmation {
        let toolName: String
        /// The pending change, in the user's language.
        let text: String
    }

    struct Undo {
        let text: String
        let expiresAt: Date
    }

    struct Notice {
        enum Action {
            case none
            /// Out of hosted actions: buy credits or upgrade.
            case buyCredits
            /// Open Settings → AI Providers & Fallbacks.
            case openAISettings
        }

        let text: String
        let action: Action
    }

    let id: UUID
    var content: Content

    init(id: UUID = UUID(), content: Content) {
        self.id = id
        self.content = content
    }

    var isConfirmation: Bool {
        if case .confirmation = content { return true }
        return false
    }
}

/// The cards on screen, newest last. Undo cards expire on their own.
@MainActor
@Observable
final class VoiceAssistantCardStore {
    /// More than this and the oldest cards make room.
    static let maximumCards = 4

    private(set) var cards: [VoiceAssistantCard] = []
    @ObservationIgnored private var expiryTasks: [UUID: Task<Void, Never>] = [:]
    /// Called when an undo card expires, so its action can be dropped.
    @ObservationIgnored var onExpire: ((UUID) -> Void)?

    func show(_ card: VoiceAssistantCard) {
        if case .draft(let draft) = card.content {
            // A redone draft replaces its old card.
            cards.removeAll {
                if case .draft(let existing) = $0.content { return existing.draftID == draft.draftID }
                return false
            }
        }
        cards.append(card)
        while cards.count > Self.maximumCards {
            // Pending confirmations stay until answered; drop the oldest other card.
            guard let index = cards.firstIndex(where: { !$0.isConfirmation }) else { break }
            remove(id: cards[index].id)
        }
        if case .undo(let undo) = card.content {
            let id = card.id
            expiryTasks[id] = Task { [weak self] in
                try? await Task.sleep(for: .seconds(max(0, undo.expiresAt.timeIntervalSinceNow)))
                guard !Task.isCancelled else { return }
                self?.remove(id: id)
                self?.onExpire?(id)
            }
        }
    }

    func remove(id: UUID) {
        expiryTasks.removeValue(forKey: id)?.cancel()
        cards.removeAll { $0.id == id }
    }

    func card(id: UUID) -> VoiceAssistantCard? {
        cards.first { $0.id == id }
    }

    func markDraftLogged(_ draftID: String, logged: Bool = true) {
        guard let index = cards.firstIndex(where: {
            if case .draft(let draft) = $0.content { return draft.draftID == draftID }
            return false
        }), case .draft(var draft) = cards[index].content else { return }
        draft.isLogged = logged
        cards[index].content = .draft(draft)
    }

    func clear() {
        for task in expiryTasks.values { task.cancel() }
        expiryTasks.removeAll()
        cards.removeAll()
    }
}
