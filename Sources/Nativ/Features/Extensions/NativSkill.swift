import Foundation

struct NativSkill: Codable, Equatable, Identifiable, Sendable {
    var id: UUID
    var name: String
    var instructions: String
    var isEnabled: Bool

    init(
        id: UUID = UUID(),
        name: String = "",
        instructions: String = "",
        isEnabled: Bool = true
    ) {
        self.id = id
        self.name = name
        self.instructions = instructions
        self.isEnabled = isEnabled
    }
}
