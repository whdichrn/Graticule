import AppKit
import Combine
import Foundation
import UniformTypeIdentifiers

enum FileAssociationManager {
    static let supportedExtensions: [String] = ["nc", "nc4", "cdf", "grd", "h5", "hdf", "npz"]

    struct AssociationStatus: Identifiable, Sendable {
        let ext: String
        let utiIdentifier: String
        let currentAppName: String
        let currentAppURL: URL?
        let isDefault: Bool

        var id: String { ext }
    }

    static func utType(forExtension ext: String) -> UTType? {
        UTType(filenameExtension: ext)
    }

    static func currentAssociations(targetBundleURL: URL? = nil) -> [AssociationStatus] {
        let targetURL = (targetBundleURL ?? Bundle.main.bundleURL).standardizedFileURL
        return supportedExtensions.map { ext in
            guard let type = utType(forExtension: ext) else {
                return AssociationStatus(ext: ext, utiIdentifier: "unknown", currentAppName: "Unavailable", currentAppURL: nil, isDefault: false)
            }
            let handlerURL = NSWorkspace.shared.urlForApplication(toOpen: type)?.standardizedFileURL
            let appName = handlerURL?.deletingPathExtension().lastPathComponent ?? "None"
            let matches = handlerURL != nil && handlerURL == targetURL
            return AssociationStatus(
                ext: ext,
                utiIdentifier: type.identifier,
                currentAppName: appName,
                currentAppURL: handlerURL,
                isDefault: matches
            )
        }
    }

    static func registerAsDefaultForAll(appURL: URL? = nil) async throws -> [String: String] {
        let targetURL = (appURL ?? Bundle.main.bundleURL).standardizedFileURL
        guard targetURL.pathExtension == "app", FileManager.default.fileExists(atPath: targetURL.path) else {
            throw NSError(
                domain: "Graticule.FileAssociation",
                code: 1,
                userInfo: [NSLocalizedDescriptionKey: "Build and launch Graticule.app before registering as default handler."]
            )
        }

        var results: [String: String] = [:]
        for ext in supportedExtensions {
            guard let type = utType(forExtension: ext) else {
                results[ext] = "Unsupported UTType"
                continue
            }
            try await NSWorkspace.shared.setDefaultApplication(at: targetURL, toOpen: type)
            results[ext] = "Registered (\(type.identifier))"
        }
        return results
    }
}

enum DatasetOpenBehavior: String, CaseIterable, Identifiable, Sendable {
    case smart
    case inspectOnly
    case alwaysPlot

    var id: String { rawValue }

    var label: String {
        switch self {
        case .smart:
            return "Smart (auto-plot single grid, inspect multi-variable)"
        case .inspectOnly:
            return "Inspect only (show Info, plot on demand)"
        case .alwaysPlot:
            return "Always auto-plot first variable"
        }
    }
}

@MainActor
final class BackendEnvironment: ObservableObject {
    private enum Keys {
        static let pythonPath = "Graticule.pythonPath"
        static let gmtPath = "Graticule.gmtPath"
        static let sourceRoot = "Graticule.sourceRoot"
        static let cnBorderDir = "Graticule.cnBorderDir"
        static let enableCNBorders = "Graticule.enableCNBorders"
        static let boxSelectOpensNewTab = "Graticule.boxSelectOpensNewTab"
        static let datasetOpenBehavior = "Graticule.datasetOpenBehavior"
        static let defaultPreviewLOD = "Graticule.defaultPreviewLOD"
        static let defaultPreviewDPI = "Graticule.defaultPreviewDPI"
    }

    @Published var pythonPathOverride: String {
        didSet { UserDefaults.standard.set(pythonPathOverride, forKey: Keys.pythonPath) }
    }
    @Published var gmtPathOverride: String {
        didSet { UserDefaults.standard.set(gmtPathOverride, forKey: Keys.gmtPath) }
    }
    @Published var sourceRootOverride: String {
        didSet { UserDefaults.standard.set(sourceRootOverride, forKey: Keys.sourceRoot) }
    }
    @Published var cnBorderDirOverride: String {
        didSet { UserDefaults.standard.set(cnBorderDirOverride, forKey: Keys.cnBorderDir) }
    }
    @Published var enableCNBorders: Bool {
        didSet { UserDefaults.standard.set(enableCNBorders, forKey: Keys.enableCNBorders) }
    }
    @Published var boxSelectOpensNewTab: Bool {
        didSet { UserDefaults.standard.set(boxSelectOpensNewTab, forKey: Keys.boxSelectOpensNewTab) }
    }
    @Published var datasetOpenBehavior: DatasetOpenBehavior {
        didSet { UserDefaults.standard.set(datasetOpenBehavior.rawValue, forKey: Keys.datasetOpenBehavior) }
    }
    @Published var defaultPreviewLOD: Bool {
        didSet { UserDefaults.standard.set(defaultPreviewLOD, forKey: Keys.defaultPreviewLOD) }
    }
    @Published var defaultPreviewDPI: Int {
        didSet { UserDefaults.standard.set(defaultPreviewDPI, forKey: Keys.defaultPreviewDPI) }
    }

    init() {
        let defaults = UserDefaults.standard
        self.pythonPathOverride = defaults.string(forKey: Keys.pythonPath) ?? ""
        self.gmtPathOverride = defaults.string(forKey: Keys.gmtPath) ?? ""
        self.sourceRootOverride = defaults.string(forKey: Keys.sourceRoot) ?? ""
        self.cnBorderDirOverride = defaults.string(forKey: Keys.cnBorderDir) ?? ""
        self.enableCNBorders = defaults.object(forKey: Keys.enableCNBorders) as? Bool ?? false
        self.boxSelectOpensNewTab = defaults.object(forKey: Keys.boxSelectOpensNewTab) as? Bool ?? false
        let behaviorRaw = defaults.string(forKey: Keys.datasetOpenBehavior) ?? ""
        self.datasetOpenBehavior = DatasetOpenBehavior(rawValue: behaviorRaw) ?? .smart
        self.defaultPreviewLOD = defaults.object(forKey: Keys.defaultPreviewLOD) as? Bool ?? true
        let dpi = defaults.integer(forKey: Keys.defaultPreviewDPI)
        self.defaultPreviewDPI = dpi > 0 ? dpi : 200
    }

    func resetOverridesToAutoDetect() {
        pythonPathOverride = ""
        gmtPathOverride = ""
        sourceRootOverride = ""
        cnBorderDirOverride = ""
    }

    var resolvedPythonPath: String? {
        Self.detectPythonPath(override: pythonPathOverride)
    }

    var resolvedGMTPath: String? {
        Self.detectGMTPath(override: gmtPathOverride, pythonPath: resolvedPythonPath)
    }

    var resolvedSourceRoot: String? {
        Self.detectSourceRoot(override: sourceRootOverride)
    }

    var resolvedGhostscriptPath: String? {
        Self.detectGhostscriptPath(gmtPath: resolvedGMTPath, pythonPath: resolvedPythonPath)
    }

    nonisolated static func detectGhostscriptPath(gmtPath: String? = nil, pythonPath: String? = nil) -> String? {
        let fm = FileManager.default
        let env = ProcessInfo.processInfo.environment
        var candidates: [String] = []

        if let gmtPath, !gmtPath.isEmpty {
            let gmtURL = URL(fileURLWithPath: gmtPath)
            candidates.append(gmtURL.deletingLastPathComponent().appendingPathComponent("gs").path)
            // MacPorts layout: /opt/local/lib/gmt6/bin/gmt -> /opt/local/bin/gs
            var cursor = gmtURL.deletingLastPathComponent()
            for _ in 0..<5 {
                if cursor.lastPathComponent.hasPrefix("gmt"),
                   cursor.deletingLastPathComponent().lastPathComponent == "lib" {
                    candidates.append(cursor.deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("bin/gs").path)
                    break
                }
                let parent = cursor.deletingLastPathComponent()
                if parent.path == cursor.path { break }
                cursor = parent
            }
        }
        if let pythonPath, !pythonPath.isEmpty {
            candidates.append(URL(fileURLWithPath: pythonPath).deletingLastPathComponent().appendingPathComponent("gs").path)
        }
        candidates.append(contentsOf: [
            "/opt/local/bin/gs",
            "/opt/homebrew/bin/gs",
            "/usr/local/bin/gs",
            "/usr/bin/gs",
        ])
        if let pathEnv = env["PATH"] {
            for dir in pathEnv.split(separator: ":") {
                candidates.append(URL(fileURLWithPath: String(dir)).appendingPathComponent("gs").path)
            }
        }

        for path in candidates where fm.isExecutableFile(atPath: path) {
            return path
        }
        return nil
    }

    nonisolated static func detectPythonPath(override: String = "") -> String? {
        let fm = FileManager.default
        let home = fm.homeDirectoryForCurrentUser.path
        let info = Bundle.main.infoDictionary ?? [:]
        let env = ProcessInfo.processInfo.environment

        var candidates: [String] = []
        if !override.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            candidates.append(override.trimmingCharacters(in: .whitespacesAndNewlines))
        }
        if let envPy = env["GRATICULE_PYTHON"], !envPy.isEmpty {
            candidates.append(envPy)
        }
        if let legacyPy = env["GMT_PANOPLY_PYTHON"], !legacyPy.isEmpty {
            candidates.append(legacyPy)
        }
        if let bundlePy = info["GraticuleDefaultPython"] as? String, !bundlePy.isEmpty {
            candidates.append(bundlePy)
        }

        candidates.append(contentsOf: [
            "\(home)/micromamba/envs/dev/bin/python",
            "\(home)/miniforge3/envs/dev/bin/python",
            "\(home)/miniconda3/envs/dev/bin/python",
            "\(home)/mambaforge/envs/dev/bin/python",
        ])

        for root in ["\(home)/micromamba/envs", "\(home)/miniforge3/envs", "\(home)/miniconda3/envs", "\(home)/anaconda3/envs"] {
            if let subdirs = try? fm.contentsOfDirectory(atPath: root) {
                for name in subdirs.sorted() {
                    candidates.append("\(root)/\(name)/bin/python")
                }
            }
        }

        candidates.append(contentsOf: [
            "/opt/homebrew/bin/python3",
            "/usr/local/bin/python3",
            "/usr/bin/python3"
        ])

        for path in candidates where fm.isExecutableFile(atPath: path) {
            return path
        }
        return nil
    }

    nonisolated static func detectGMTPath(override: String = "", pythonPath: String? = nil) -> String? {
        let fm = FileManager.default
        let info = Bundle.main.infoDictionary ?? [:]
        let env = ProcessInfo.processInfo.environment

        var candidates: [String] = []
        if !override.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            candidates.append(override.trimmingCharacters(in: .whitespacesAndNewlines))
        }
        if let envGmt = env["GMT_BIN"], !envGmt.isEmpty {
            candidates.append(envGmt)
        }
        if let bundleGmt = info["GraticuleDefaultGMT"] as? String, !bundleGmt.isEmpty {
            candidates.append(bundleGmt)
        }
        if let pythonPath {
            let sibling = URL(fileURLWithPath: pythonPath).deletingLastPathComponent().appendingPathComponent("gmt").path
            candidates.append(sibling)
        }
        candidates.append(contentsOf: [
            "/opt/local/lib/gmt6/bin/gmt",
            "/opt/local/bin/gmt6",
            "/opt/local/bin/gmt",
            "/opt/homebrew/bin/gmt",
            "/usr/local/bin/gmt",
            "/usr/bin/gmt"
        ])

        for path in candidates where fm.isExecutableFile(atPath: path) {
            return path
        }
        return nil
    }

    private final class BundleAnchor {}

    nonisolated static func detectSourceRoot(override: String = "") -> String? {
        let fm = FileManager.default
        let info = Bundle.main.infoDictionary ?? [:]
        let env = ProcessInfo.processInfo.environment

        func isValidRoot(_ dir: String) -> Bool {
            let probe = URL(fileURLWithPath: dir).appendingPathComponent("graticule/backend/rpc_server.py").path
            return fm.fileExists(atPath: probe)
        }

        let explicitCandidates = [
            override.trimmingCharacters(in: .whitespacesAndNewlines),
            env["GRATICULE_ROOT"] ?? "",
            env["GMT_PANOPLY_ROOT"] ?? "",
            (info["GraticuleSourceRoot"] as? String) ?? "",
            Bundle.main.resourceURL?.appendingPathComponent("backend").path ?? "",
        ]
        for candidate in explicitCandidates where !candidate.isEmpty && isValidRoot(candidate) {
            return candidate
        }

        let startURLs = [
            URL(fileURLWithPath: fm.currentDirectoryPath),
            Bundle(for: BundleAnchor.self).bundleURL,
            Bundle.main.bundleURL
        ]
        for start in startURLs {
            var cursor = start.standardizedFileURL
            for _ in 0..<10 {
                if isValidRoot(cursor.path) {
                    return cursor.path
                }
                let parent = cursor.deletingLastPathComponent()
                if parent.path == cursor.path { break }
                cursor = parent
            }
        }
        return nil
    }
}
