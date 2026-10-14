import Foundation

public struct StemSource: Equatable {
    public let name: String
    public let url: URL
}

public struct SoundRazorImport {
    public let title: String
    public let stems: [StemSource]
    public static let audioExtensions: Set<String> = ["wav", "aif", "aiff", "mp3", "m4a", "aac", "caf", "flac"]

    public static func inspect(_ directory: URL) throws -> SoundRazorImport {
        guard directory.isFileURL else { throw PlaythrError.message("Choose a local stems folder.") }
        let fm = FileManager.default
        let child = directory.appendingPathComponent("stems", isDirectory: true)
        let folder = fm.fileExists(atPath: child.path) ? child : directory
        guard try fm.attributesOfItem(atPath: folder.path)[.type] as? FileAttributeType == .typeDirectory else {
            throw PlaythrError.message("Choose a real stems folder, not a link.")
        }
        let songFolder = directory.lastPathComponent == "stems" ? directory.deletingLastPathComponent() : directory
        let metadataURL = songFolder.appendingPathComponent("metadata.json")
        var title = songFolder.lastPathComponent
        if fm.fileExists(atPath: metadataURL.path) {
            let metadata = try JSONSerialization.jsonObject(with: ProjectStore.readJSON(metadataURL, maximumBytes: 1024 * 1024)) as? [String: Any]
            if let value = metadata?["title"] as? String, !value.isEmpty { title = value }
        }
        var settings: [String: Any] = [:]
        let settingsURL = folder.appendingPathComponent("separation.json")
        if fm.fileExists(atPath: settingsURL.path) {
            guard let object = try JSONSerialization.jsonObject(with: ProjectStore.readJSON(settingsURL, maximumBytes: 1024 * 1024)) as? [String: Any] else {
                throw PlaythrError.message("Sound Razor’s separation.json is not a JSON object.")
            }
            settings = object
        }
        let files = try fm.contentsOfDirectory(at: folder, includingPropertiesForKeys: [.isRegularFileKey, .isSymbolicLinkKey])
            .filter { url in
                let properties = try url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey])
                return properties.isRegularFile == true && properties.isSymbolicLink != true && audioExtensions.contains(url.pathExtension.lowercased())
            }
        let names = Set(files.map(\.lastPathComponent))
        let split = (settings["guitar_split"] as? [[String: Any]]) ?? (settings["guitar_split"] as? [String: Any]).map { [$0] } ?? []
        let hasLeadRhythm = settings["lead_rhythm_split"] as? Bool == true || settings["lead_rhythm_split"] as? [String: Any] != nil
        let leadRhythm = hasLeadRhythm && names.contains("lead.wav") && names.contains("rhythm.wav")
        let targetSplit = !split.isEmpty && names.contains("guitar-target-1.wav")
        var labels: [String: String] = ["guitar-remainder": "Guitar remainder"]
        for (index, item) in split.enumerated() { labels["guitar-target-\(index + 1)"] = item["title"] as? String }
        if let first = split.first?["title"] as? String { labels["guitar-target"] = first }
        let order = ["vocals", "guitar", "lead", "rhythm", "bass", "drums", "piano", "other", "instrumental"]
        let stems = files.filter { !(($0.lastPathComponent == "guitar.wav") && (leadRhythm || targetSplit)) }
            .sorted {
                let a = order.firstIndex(of: $0.deletingPathExtension().lastPathComponent) ?? 99
                let b = order.firstIndex(of: $1.deletingPathExtension().lastPathComponent) ?? 99
                return a == b ? $0.lastPathComponent < $1.lastPathComponent : a < b
            }.map { url in
                let name = url.deletingPathExtension().lastPathComponent
                return StemSource(name: labels[name] ?? name.replacingOccurrences(of: "-", with: " ").capitalized, url: url)
            }
        guard !stems.isEmpty else { throw PlaythrError.message("No supported audio files were found. Choose a song folder or its stems folder.") }
        return SoundRazorImport(title: title, stems: stems)
    }
}
