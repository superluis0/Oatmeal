import Foundation

/// Reuses the Parakeet model already downloaded by Spokenly so FluidAudio can skip
/// its ~450 MB first-run download. Best-effort: if anything is missing or the copy
/// fails, FluidAudio falls back to downloading normally.
enum ModelProvisioner {

    private static let modelFolder = "parakeet-tdt-0.6b-v2-coreml"
    /// One of the required model sub-bundles — used to detect a complete install.
    private static let marker = "Encoder.mlmodelc"

    /// Copies Spokenly's Parakeet model into FluidAudio's default models directory
    /// if FluidAudio doesn't already have it.
    static func provisionParakeetIfNeeded() {
        let fm = FileManager.default
        guard let appSupport = fm.urls(for: .applicationSupportDirectory, in: .userDomainMask).first else { return }

        let modelsDir = appSupport.appendingPathComponent("FluidAudio/Models", isDirectory: true)
        let dest = modelsDir.appendingPathComponent(modelFolder, isDirectory: true)

        // Already present (whether copied by us before or downloaded by FluidAudio).
        if fm.fileExists(atPath: dest.appendingPathComponent(marker).path) { return }

        let source = fm.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Containers/app.spokenly/Data/Library/Application Support/FluidAudio/Models", isDirectory: true)
            .appendingPathComponent(modelFolder, isDirectory: true)

        guard fm.fileExists(atPath: source.appendingPathComponent(marker).path) else { return }

        do {
            try fm.createDirectory(at: modelsDir, withIntermediateDirectories: true)
            try fm.copyItem(at: source, to: dest)
        } catch {
            // Leave no partial copy behind; FluidAudio will download instead.
            try? fm.removeItem(at: dest)
        }
    }
}
