import AppKit
import Foundation

@MainActor
final class ConfigStore: ObservableObject {
    @Published private(set) var config: AppConfig

    let appSupportDirectory: URL
    let configFileURL: URL

    init(fileManager: FileManager = .default) {
        let baseDirectory = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        appSupportDirectory = baseDirectory.appendingPathComponent("GPTUsageBar", isDirectory: true)
        configFileURL = appSupportDirectory.appendingPathComponent("config.json")

        try? fileManager.createDirectory(at: appSupportDirectory, withIntermediateDirectories: true)

        if !fileManager.fileExists(atPath: configFileURL.path) {
            let sampleData = try? JSONEncoder.prettyPrinted.encode(AppConfig.sample)
            try? sampleData?.write(to: configFileURL, options: .atomic)
        }

        config = (try? Self.loadConfig(from: configFileURL)) ?? .sample
    }

    func reload() throws {
        config = try Self.loadConfig(from: configFileURL)
    }

    func openConfigInEditor() {
        NSWorkspace.shared.open(configFileURL)
    }

    func revealSupportFolder() {
        NSWorkspace.shared.selectFile(configFileURL.path, inFileViewerRootedAtPath: appSupportDirectory.path)
    }

    func save(_ config: AppConfig) throws {
        let data = try JSONEncoder.prettyPrinted.encode(config)
        try data.write(to: configFileURL, options: .atomic)
        self.config = config
    }

    private static func loadConfig(from url: URL) throws -> AppConfig {
        let data = try Data(contentsOf: url)
        return try JSONDecoder().decode(AppConfig.self, from: data)
    }
}

private extension JSONEncoder {
    static var prettyPrinted: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return encoder
    }
}
