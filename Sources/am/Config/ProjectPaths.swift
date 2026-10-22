import Foundation

/// Locations of a project's AgentMux files.
struct ProjectPaths {
    let root: String
    let directory: String
    let configFile: String
    let legacyYAMLFile: String
    let secretsFile: String
    let stateFile: String

    static let directoryName = ".agentmux"

    init(root: String) {
        self.root = root
        let directory = (root as NSString).appendingPathComponent(Self.directoryName)
        self.directory = directory
        self.configFile = (directory as NSString).appendingPathComponent("gateways.json")
        self.legacyYAMLFile = (directory as NSString).appendingPathComponent("gateways.yaml")
        self.secretsFile = (directory as NSString).appendingPathComponent("secrets.json")
        self.stateFile = (directory as NSString).appendingPathComponent("state.json")
    }

    /// Where an agent's own configuration lives once it has been linked.
    func linkedDirectory(for agent: Agent) -> String {
        (directory as NSString).appendingPathComponent(agent.configDirectoryName)
    }

    /// The link in the project root that points at it.
    func projectLink(for agent: Agent) -> String {
        (root as NSString).appendingPathComponent(agent.configDirectoryName)
    }

    /// Where whatever was there before is set aside, with the user's say-so.
    func linkBackup(for agent: Agent) -> String {
        (root as NSString).appendingPathComponent("\(agent.configDirectoryName)_bak")
    }

    /// Walks up from `startDirectory` looking for the nearest `.agentmux/gateways.json`.
    ///
    /// The search stops after examining the git root or the home directory, so a
    /// project never silently picks up an unrelated parent's gateways. Nothing
    /// falls back to the home directory: configuration is per project by design.
    static func discover(from startDirectory: String) -> ProjectPaths? {
        let fileManager = FileManager.default
        let home = NSHomeDirectory()
        var current = startDirectory

        while true {
            let paths = ProjectPaths(root: current)
            if fileManager.fileExists(atPath: paths.configFile) { return paths }

            let gitDirectory = (current as NSString).appendingPathComponent(".git")
            if current == home || current == "/" || fileManager.fileExists(atPath: gitDirectory) {
                return nil
            }

            let parent = (current as NSString).deletingLastPathComponent
            if parent == current || parent.isEmpty { return nil }
            current = parent
        }
    }

    /// Resolves the project for a command that needs one, with the guidance a
    /// user needs when there is none — including the case where only the
    /// pre-JSON config is present.
    static func require(from startDirectory: String = FileManager.default.currentDirectoryPath)
        throws -> ProjectPaths
    {
        if let paths = discover(from: startDirectory) { return paths }

        let here = ProjectPaths(root: startDirectory)
        if FileManager.default.fileExists(atPath: here.legacyYAMLFile) {
            throw AgentMuxError(
                "Found .agentmux/gateways.yaml from an older version; this one reads gateways.json",
                hint: "Run `am init` to set it up again, or convert the file to JSON yourself"
            )
        }
        throw AgentMuxError(
            "No .agentmux/gateways.json in this directory or above it",
            hint: "Run `am init` in the project root to create it"
        )
    }
}
