import Foundation

/// Remembers the last gateway chosen per agent, so the menu can preselect it.
struct LaunchState: Codable {
    var lastGateway: [String: String]?

    static func load(_ file: String) -> LaunchState {
        guard let data = FileManager.default.contents(atPath: file),
              let state = try? JSONDecoder().decode(LaunchState.self, from: data)
        else {
            // A missing or corrupt state file is never worth failing a launch over.
            return LaunchState(lastGateway: nil)
        }
        return state
    }

    static func remember(gateway: String, for agent: Agent, in file: String) {
        var state = load(file)
        var map = state.lastGateway ?? [:]
        map[agent.id] = gateway
        state.lastGateway = map

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        guard let data = try? encoder.encode(state) else { return }
        try? data.write(to: URL(fileURLWithPath: file), options: .atomic)
        try? FileManager.default.setAttributes(
            [.posixPermissions: 0o600], ofItemAtPath: file
        )
    }
}
