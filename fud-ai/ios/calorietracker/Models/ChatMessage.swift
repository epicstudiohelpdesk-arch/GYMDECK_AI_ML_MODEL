import Foundation

struct ChatMessage: Identifiable, Codable, Equatable {
    enum Role: String, Codable {
        case user
        case assistant
    }

    let id: UUID
    let role: Role
    let content: String
    let timestamp: Date
    let attachmentImageData: Data?
    /// Workout changes Coach proposed in this reply, shown as Add / Dismiss cards. Optional so
    /// conversations saved before proposals still decode.
    var exerciseProposals: [CoachExerciseProposal]?

    init(
        id: UUID = UUID(),
        role: Role,
        content: String,
        timestamp: Date = .now,
        attachmentImageData: Data? = nil,
        exerciseProposals: [CoachExerciseProposal]? = nil
    ) {
        self.id = id
        self.role = role
        self.content = content
        self.timestamp = timestamp
        self.attachmentImageData = attachmentImageData
        self.exerciseProposals = exerciseProposals
    }

    /// The text sent back to the model as history: the reply plus what became of each proposal.
    var contextContent: String {
        guard let exerciseProposals, !exerciseProposals.isEmpty else { return content }
        return ([content] + exerciseProposals.map(\.contextLine)).joined(separator: "\n")
    }
}
