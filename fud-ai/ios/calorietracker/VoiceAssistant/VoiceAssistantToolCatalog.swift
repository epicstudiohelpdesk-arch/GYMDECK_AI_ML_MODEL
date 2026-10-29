import Foundation

/// One assistant action from the bundled `VoiceAssistantTools.json` (a copy of
/// `shared/voice-assistant/tools.json`).
struct VoiceAssistantToolSpec: Equatable {
    enum Effect: String {
        case read
        case navigate
        case write
        case destructive
    }

    enum Confirmation: String {
        /// Runs straight away.
        case never
        /// Always waits for the user's yes (deletes).
        case always
        /// Waits for the user's yes while Confirm before saving is on.
        case setting
    }

    let name: String
    let description: String
    let effect: Effect
    let confirm: Confirmation
    /// Hidden while the workout diary is turned off.
    let requiresWorkoutDiary: Bool
    /// JSON Schema of the arguments, as JSON text.
    let parametersJSON: String
}

/// The tools a session declares: the bundled catalog plus Coach's data tools.
enum VoiceAssistantToolCatalog {
    static let resourceName = "VoiceAssistantTools"

    enum CatalogError: Error {
        case missingResource
        case invalidFormat
    }

    /// The bundled catalog, read once. An unreadable catalog leaves the assistant
    /// with Coach's data tools only, rather than failing the whole session.
    static let bundled: [VoiceAssistantToolSpec] = (try? load()) ?? []

    static func load(bundle: Bundle = .main) throws -> [VoiceAssistantToolSpec] {
        guard let url = bundle.url(forResource: resourceName, withExtension: "json") else {
            throw CatalogError.missingResource
        }
        return try parse(Data(contentsOf: url))
    }

    static func parse(_ data: Data) throws -> [VoiceAssistantToolSpec] {
        guard let root = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let tools = root["tools"] as? [[String: Any]] else {
            throw CatalogError.invalidFormat
        }
        return try tools.map { tool in
            guard let name = tool["name"] as? String,
                  let description = tool["description"] as? String,
                  let effect = (tool["effect"] as? String).flatMap(VoiceAssistantToolSpec.Effect.init(rawValue:)),
                  let confirm = (tool["confirm"] as? String).flatMap(VoiceAssistantToolSpec.Confirmation.init(rawValue:)),
                  let parameters = tool["parameters"] as? [String: Any] else {
                throw CatalogError.invalidFormat
            }
            return VoiceAssistantToolSpec(
                name: name,
                description: description,
                effect: effect,
                confirm: confirm,
                requiresWorkoutDiary: tool["workout"] as? Bool ?? false,
                parametersJSON: LiveJSON.string(parameters)
            )
        }
    }

    static func spec(named name: String, in specs: [VoiceAssistantToolSpec] = bundled) -> VoiceAssistantToolSpec? {
        specs.first { $0.name == name }
    }

    /// Coach's data tools offered to the assistant, honoring the workout gate.
    static func coachToolNames(workoutDiaryEnabled: Bool) -> [String] {
        CoachTools.nutritionToolNames + (workoutDiaryEnabled ? CoachTools.workoutToolNames : [])
    }

    /// Every declaration for a session: catalog tools (without the workout ones
    /// when the diary is off) followed by Coach's data tools.
    static func declarations(
        specs: [VoiceAssistantToolSpec] = bundled,
        workoutDiaryEnabled: Bool
    ) -> [LiveToolDeclaration] {
        let actions = specs
            .filter { workoutDiaryEnabled || !$0.requiresWorkoutDiary }
            .map { LiveToolDeclaration(name: $0.name, description: $0.description, parametersJSON: $0.parametersJSON) }
        let data = coachToolNames(workoutDiaryEnabled: workoutDiaryEnabled).map { name in
            LiveToolDeclaration(
                name: name,
                description: CoachTools.toolDescriptions[name] ?? "",
                parametersJSON: LiveJSON.string(CoachTools.parameterSchema(for: name))
            )
        }
        return actions + data
    }
}
