import Foundation

public struct ProjectStore: Sendable {
    public let root: URL
    public init(root: URL) { self.root = root.standardizedFileURL }
    public var manifest: URL { root.appendingPathComponent("project.json") }
    public var mediaDirectory: URL { root.appendingPathComponent("Media", isDirectory: true) }

    public static func create(at root: URL, name: String) throws -> ProjectStore {
        let store = ProjectStore(root: root)
        guard !FileManager.default.fileExists(atPath: root.path) else {
            throw PlaythrError.message("That project folder already exists. Open it or choose a new name.")
        }
        try FileManager.default.createDirectory(at: store.mediaDirectory, withIntermediateDirectories: true)
        try store.save(Project(name: name))
        return store
    }

    public func mediaURL(_ path: String) throws -> URL {
        try validateMediaPath(path)
        let url = root.appendingPathComponent(path)
        let resolvedRoot = root.resolvingSymlinksInPath().path + "/"
        guard url.resolvingSymlinksInPath().path.hasPrefix(resolvedRoot),
              !(try mediaDirectory.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink ?? false) else {
            throw PlaythrError.message("Media must remain inside the project folder.")
        }
        return url
    }

    public func load() throws -> Project {
        let data = try Data(contentsOf: manifest)
        let project = try JSONDecoder().decode(Project.self, from: data)
        try project.validate()
        for file in project.tracks.map(\.file) + project.takes.map(\.file) {
            let url = try mediaURL(file)
            guard FileManager.default.fileExists(atPath: url.path) else {
                throw PlaythrError.message("Missing media: \(file). Restore it to this project’s Media folder before opening.")
            }
        }
        return project
    }

    public func save(_ project: Project) throws {
        try project.validate()
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(project).write(to: manifest, options: .atomic)
    }

    public func copyMedia(from source: URL) throws -> String {
        let ext = source.pathExtension.lowercased()
        let file = "Media/\(UUID().uuidString).\(ext.isEmpty ? "wav" : ext)"
        try FileManager.default.copyItem(at: source, to: mediaURL(file))
        return file
    }

    public func newTakePath() throws -> (String, URL) {
        let path = "Media/\(UUID().uuidString).mov"
        return (path, try mediaURL(path))
    }

    /// A crash can leave a finalized movie outside the manifest. Never delete it.
    public func unregisteredMovies(in project: Project) throws -> [URL] {
        let known = Set(project.takes.map(\.file))
        return try FileManager.default.contentsOfDirectory(at: mediaDirectory, includingPropertiesForKeys: nil)
            .filter { $0.pathExtension == "mov" && !$0.lastPathComponent.hasPrefix(".") && !known.contains("Media/" + $0.lastPathComponent) }
    }
}
