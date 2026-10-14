import Foundation

public struct ProjectStore: Sendable {
    static let maximumManifestBytes = 16 * 1024 * 1024
    public let root: URL
    public init(root: URL) { self.root = root.standardizedFileURL }
    public var manifest: URL { root.appendingPathComponent("project.json") }
    public var mediaDirectory: URL { root.appendingPathComponent("Media", isDirectory: true) }

    public static func create(at root: URL, name: String) throws -> ProjectStore {
        guard root.isFileURL else { throw PlaythrError.message("Choose a local project folder.") }
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
        try validateMediaDirectory()
        let url = root.appendingPathComponent(path)
        let resolvedRoot = root.resolvingSymlinksInPath().path + "/"
        guard url.resolvingSymlinksInPath().path.hasPrefix(resolvedRoot),
              !(try mediaDirectory.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink ?? false) else {
            throw PlaythrError.message("Media must remain inside the project folder.")
        }
        try Self.validateRegularFile(url, allowMissing: true)
        return url
    }

    func validateMediaDirectory() throws {
        guard root.isFileURL,
              try FileManager.default.attributesOfItem(atPath: mediaDirectory.path)[.type] as? FileAttributeType == .typeDirectory else {
            throw PlaythrError.message("Media must be a real directory inside the project, not a link.")
        }
    }

    /// Reject links, directories and special files (such as FIFOs) before opening them.
    static func validateRegularFile(_ url: URL, allowMissing: Bool = false) throws {
        guard url.isFileURL else { throw PlaythrError.message("Choose a local file.") }
        do {
            let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
            guard attributes[.type] as? FileAttributeType == .typeRegular else {
                throw PlaythrError.message("\(url.lastPathComponent) must be a regular file, not a link or special file.")
            }
        } catch let error as CocoaError where allowMissing && (error.code == .fileReadNoSuchFile || error.code == .fileNoSuchFile) {
            return
        }
    }

    static func readJSON(_ url: URL, maximumBytes: Int) throws -> Data {
        try validateRegularFile(url)
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        let data = try handle.read(upToCount: maximumBytes + 1) ?? Data()
        guard data.count <= maximumBytes else { throw PlaythrError.message("\(url.lastPathComponent) is too large to open safely.") }
        return data
    }

    public func load() throws -> Project {
        try validateMediaDirectory()
        let data = try Self.readJSON(manifest, maximumBytes: Self.maximumManifestBytes)
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
        try validateMediaDirectory()
        try Self.validateRegularFile(manifest, allowMissing: true)
        for file in project.tracks.map(\.file) + project.takes.map(\.file) { _ = try mediaURL(file) }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(project)
        guard data.count <= Self.maximumManifestBytes else { throw PlaythrError.message("This project exceeds the 16 MiB manifest limit.") }
        try data.write(to: manifest, options: .atomic)
    }

    public func copyMedia(from source: URL) throws -> String {
        // Copy the selected file's contents, never a link that would escape the project.
        let source = source.resolvingSymlinksInPath()
        try Self.validateRegularFile(source)
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
        try validateMediaDirectory()
        let known = Set(project.takes.map(\.file))
        return try FileManager.default.contentsOfDirectory(at: mediaDirectory, includingPropertiesForKeys: nil)
            .filter { $0.pathExtension == "mov" && !$0.lastPathComponent.hasPrefix(".") && !known.contains("Media/" + $0.lastPathComponent) }
            .filter { (try? Self.validateRegularFile($0)) != nil }
            .map { try mediaURL("Media/" + $0.lastPathComponent) }
    }
}
