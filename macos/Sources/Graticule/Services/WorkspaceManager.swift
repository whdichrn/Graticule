import AppKit
import Combine
import Foundation
import UniformTypeIdentifiers

enum InteractionMode: String, CaseIterable, Sendable {
    case pan
    case select
}

@MainActor
final class PlotSession: ObservableObject, Identifiable {
    let id: UUID
    @Published var datasetPath: String?
    @Published var variableName: String?
    @Published var inspectedTarget: InspectTarget?
    @Published var structureSheetDatasetPath: String?
    @Published var config: PlotConfig?
    @Published var recommendedProjections: [ProjectionOption] = []
    @Published var regionHistory = RegionHistoryStack()
    @Published var currentRender: RenderResult?
    @Published var hoverGrid: HoverGrid?
    @Published var cursorCoord: (lon: Double, lat: Double)?
    @Published var zoomScale: Double = 1.0
    @Published var interactionMode: InteractionMode = .pan
    @Published var isRendering: Bool = false
    @Published var isScanningRange: Bool = false
    @Published var errorMessage: String?
    @Published var statusText: String = "Ready"
    @Published var fitRequestToken: Int = 0
    @Published var actualSizeRequestToken: Int = 0
    @Published var selectedInspectorTab: InspectorTab = .map
    var parentWindowIDForTabbing: ObjectIdentifier?

    private var debounceTask: Task<Void, Never>?
    private var renderGeneration: Int = 0
    private weak var workspace: WorkspaceManager?

    init(id: UUID = UUID(), workspace: WorkspaceManager? = nil, parentWindowIDForTabbing: ObjectIdentifier? = nil) {
        self.id = id
        self.workspace = workspace
        self.parentWindowIDForTabbing = parentWindowIDForTabbing
    }

    func attach(workspace: WorkspaceManager) {
        self.workspace = workspace
    }

    func scheduleRender(delayMs: Int = 350) {
        debounceTask?.cancel()
        debounceTask = Task { [weak self] in
            if delayMs > 0 {
                try? await Task.sleep(for: .milliseconds(delayMs))
            }
            guard !Task.isCancelled, let self else { return }
            await self.renderNow()
        }
    }

    func renderNow() async {
        debounceTask?.cancel()
        guard let config, let workspace else { return }
        renderGeneration += 1
        let myGen = renderGeneration
        isRendering = true
        errorMessage = nil
        statusText = "Rendering…"

        do {
            let result = try await workspace.rpc.render(config: config, outputPath: nil, isExport: false, includeHover: true)
            guard myGen == renderGeneration else { return }
            applyRenderResult(result, styleSignature: config.styleSignature)
        } catch {
            guard myGen == renderGeneration else { return }
            isRendering = false
            errorMessage = error.localizedDescription
            statusText = "Render failed"
        }
    }

    func applyRenderResult(_ result: RenderResult, styleSignature: String, customMessage: String? = nil) {
        currentRender = result
        hoverGrid = HoverGrid(base64: result.hoverB64, size: result.hoverGridSize)
        if var cfg = config {
            cfg.region = result.resolvedConfig.region
            cfg.projection = result.resolvedConfig.projection
            self.config = cfg
        }
        regionHistory.updateCurrentRender(result, styleSignature: styleSignature)
        isRendering = false
        errorMessage = nil
        statusText = customMessage ?? String(format: "Rendered in %.2fs", result.elapsedSec)
    }

    func refreshRecommendations() async {
        guard let config, let workspace else { return }
        let varMeta = workspace.variable(named: config.variableName, inDataset: config.sourcePath)
        do {
            let options = try await workspace.rpc.recommendProjections(
                region: config.region,
                varName: config.variableName,
                varAttrs: varMeta?.attrsDictionary ?? ["description": config.variableDescription],
                isGeographic: config.isGeographic
            )
            recommendedProjections = options
            if config.projectionMode == "auto", let first = options.first {
                self.config?.projection = first.code
            }
        } catch {
            // Keep existing projections if recommendation lookup fails transiently.
        }
    }

    func resetRegionToFullExtent() async {
        guard let workspace,
              let datasetPath,
              let variableName,
              let varMeta = workspace.variable(named: variableName, inDataset: datasetPath),
              let x = varMeta.xRange,
              let y = varMeta.yRange else {
            return
        }
        let fullRegion = [x[0], x[1], y[0], y[1]]
        config?.region = fullRegion
        config?.title = varMeta.displayTitle
        await refreshRecommendations()
        if let cfg = config {
            regionHistory.reset(root: RegionEntry(
                label: "Full Grid",
                region: cfg.region,
                projection: cfg.projection,
                projectionMode: cfg.projectionMode,
                title: cfg.title
            ))
        }
        await renderNow()
    }

    func applyHistoryEntry(_ entry: RegionEntry) async {
        guard var cfg = config else { return }
        cfg.region = entry.region
        cfg.projection = entry.projection
        cfg.projectionMode = entry.projectionMode
        cfg.title = entry.title
        config = cfg
        await refreshRecommendations()

        if let cached = entry.cachedRender,
           entry.cacheStyleSignature == cfg.styleSignature,
           FileManager.default.fileExists(atPath: cached.imagePath) {
            renderGeneration += 1
            currentRender = cached
            hoverGrid = HoverGrid(base64: cached.hoverB64, size: cached.hoverGridSize)
            isRendering = false
            errorMessage = nil
            statusText = "Restored from cache"
            return
        }
        await renderNow()
    }

    func navigateBack() async {
        guard let entry = regionHistory.goBack() else { return }
        await applyHistoryEntry(entry)
    }

    func navigateForward() async {
        guard let entry = regionHistory.goForward() else { return }
        await applyHistoryEntry(entry)
    }

    func jumpToHistory(index: Int) async {
        guard let entry = regionHistory.jump(to: index) else { return }
        await applyHistoryEntry(entry)
    }
}

@MainActor
final class WorkspaceManager: ObservableObject {
    static let shared = WorkspaceManager()

    let environment = BackendEnvironment()
    let rpc = RPCClient()

    @Published var datasets: [DatasetMeta] = []
    @Published var sessions: [UUID: PlotSession] = [:]
    @Published var sessionOrder: [UUID] = []
    @Published var activeSessionID: UUID?
    @Published var pendingLaunchURLs: [URL] = []
    @Published var serverInfo: ServerInfo?
    @Published var backendError: String?
    @Published var cnBorderStatus: CNBorderStatus?
    @Published var isDownloadingCNBorder = false
    @Published var cnBorderError: String?

    var openWindowHandler: ((UUID) -> Void)?
    private var didStartBackend = false
    private var envCancellable: AnyCancellable?

    private init() {
        envCancellable = environment.objectWillChange.sink { [weak self] _ in
            MainActor.assumeIsolated {
                self?.objectWillChange.send()
            }
        }
    }

    func ensureBackendConfigured() async {
        if didStartBackend { return }
        didStartBackend = true
        await rpc.configure(
            pythonPath: environment.resolvedPythonPath,
            gmtPath: environment.resolvedGMTPath,
            sourceRoot: environment.resolvedSourceRoot
        )
        await pingBackend()
        await refreshCNBorderStatus()
    }

    func restartBackend() async {
        await rpc.restart(
            pythonPath: environment.resolvedPythonPath,
            gmtPath: environment.resolvedGMTPath,
            sourceRoot: environment.resolvedSourceRoot
        )
        didStartBackend = true
        await pingBackend()
        await refreshCNBorderStatus()
    }

    func refreshCNBorderStatus() async {
        do {
            cnBorderStatus = try await rpc.cnBorderStatus(explicitDir: environment.cnBorderDirOverride)
            cnBorderError = nil
        } catch {
            cnBorderStatus = nil
        }
    }

    func downloadCNBorder(reRenderSessionID: UUID? = nil) async {
        guard !isDownloadingCNBorder else { return }
        isDownloadingCNBorder = true
        cnBorderError = nil
        defer { isDownloadingCNBorder = false }
        do {
            let dest = environment.cnBorderDirOverride.trimmingCharacters(in: .whitespacesAndNewlines)
            var zipURL = URL(string: "https://github.com/gmt-china/china-geospatial-data/releases/latest/download/china-geospatial-data-UTF8.zip")!
            let userAgent = "Graticule/0.7.2"

            var apiReq = URLRequest(url: URL(string: "https://api.github.com/repos/gmt-china/china-geospatial-data/releases/latest")!)
            apiReq.timeoutInterval = 20
            apiReq.setValue(userAgent, forHTTPHeaderField: "User-Agent")
            if let (apiData, apiResp) = try? await URLSession.shared.data(for: apiReq),
               let httpResp = apiResp as? HTTPURLResponse,
               (200...299).contains(httpResp.statusCode),
               let json = try? JSONSerialization.jsonObject(with: apiData) as? [String: Any],
               let assets = json["assets"] as? [[String: Any]] {
                for asset in assets {
                    if let name = asset["name"] as? String, name.hasSuffix("UTF8.zip"),
                       let urlStr = asset["browser_download_url"] as? String,
                       let resolved = URL(string: urlStr) {
                        zipURL = resolved
                        break
                    }
                }
            }

            var zipReq = URLRequest(url: zipURL)
            zipReq.timeoutInterval = 120
            zipReq.setValue(userAgent, forHTTPHeaderField: "User-Agent")
            let (downloadedTempURL, downloadResp) = try await URLSession.shared.download(for: zipReq)
            if let httpResp = downloadResp as? HTTPURLResponse, !(200...299).contains(httpResp.statusCode) {
                try? FileManager.default.removeItem(at: downloadedTempURL)
                throw NSError(
                    domain: "Graticule.CNBorder",
                    code: httpResp.statusCode,
                    userInfo: [NSLocalizedDescriptionKey: "HTTP \(httpResp.statusCode) downloading \(zipURL.lastPathComponent)"]
                )
            }

            let stagedZip = FileManager.default.temporaryDirectory
                .appendingPathComponent("cn-border-\(UUID().uuidString).zip")
            try FileManager.default.copyItem(at: downloadedTempURL, to: stagedZip)
            try? FileManager.default.removeItem(at: downloadedTempURL)
            defer { try? FileManager.default.removeItem(at: stagedZip) }

            let status = try await rpc.installCNBorder(destDir: dest.isEmpty ? nil : dest, zipPath: stagedZip.path)
            cnBorderStatus = status
            if let sid = reRenderSessionID, let s = sessions[sid], s.config != nil {
                s.config?.cnBorderDir = dest
                await s.renderNow()
            }
        } catch {
            cnBorderError = error.localizedDescription
            if let sid = reRenderSessionID, let s = sessions[sid] {
                s.errorMessage = "CN-border download failed: \(error.localizedDescription)"
            }
        }
    }

    func importCNBorderZip(reRenderSessionID: UUID? = nil) async {
        guard !isDownloadingCNBorder else { return }
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.allowedContentTypes = [.zip]
        panel.prompt = "Import"
        panel.message = "Select china-geospatial-data-UTF8.zip containing CN-border .gmt files."
        guard panel.runModal() == .OK, let zipURL = panel.url else { return }

        isDownloadingCNBorder = true
        cnBorderError = nil
        defer { isDownloadingCNBorder = false }
        do {
            let dest = environment.cnBorderDirOverride.trimmingCharacters(in: .whitespacesAndNewlines)
            let status = try await rpc.installCNBorder(destDir: dest.isEmpty ? nil : dest, zipPath: zipURL.path)
            cnBorderStatus = status
            if let sid = reRenderSessionID, let s = sessions[sid], s.config != nil {
                s.config?.cnBorderDir = dest
                await s.renderNow()
            }
        } catch {
            cnBorderError = error.localizedDescription
            if let sid = reRenderSessionID, let s = sessions[sid] {
                s.errorMessage = "CN-border import failed: \(error.localizedDescription)"
            }
        }
    }

    func pingBackend() async {
        do {
            let info = try await rpc.ping()
            serverInfo = info
            if info.gsBin == nil {
                backendError = "Ghostscript (gs) not found in PATH. Install Ghostscript or check Settings (⌘,)."
            } else {
                backendError = nil
            }
        } catch {
            serverInfo = nil
            backendError = error.localizedDescription
        }
    }

    func createOrClaimInitialSessionID() -> UUID {
        if let existing = sessionOrder.first(where: { sessions[$0] != nil }) {
            return existing
        }
        let session = PlotSession(workspace: self)
        sessions[session.id] = session
        sessionOrder.append(session.id)
        activeSessionID = session.id
        return session.id
    }

    func session(for id: UUID) -> PlotSession {
        if let existing = sessions[id] {
            existing.attach(workspace: self)
            return existing
        }
        let created = PlotSession(id: id, workspace: self)
        sessions[id] = created
        if !sessionOrder.contains(id) {
            sessionOrder.append(id)
        }
        activeSessionID = id
        return created
    }

    func unregisterSession(id: UUID) {
        sessions.removeValue(forKey: id)
        sessionOrder.removeAll { $0 == id }
        if activeSessionID == id {
            activeSessionID = sessionOrder.last
        }
    }

    func spawnNewTab(from parentWindow: NSWindow? = nil) -> PlotSession {
        let targetParent = parentWindow ?? NSApp.keyWindow
        let parentID = targetParent.map(ObjectIdentifier.init)
        let session = PlotSession(workspace: self, parentWindowIDForTabbing: parentID)
        sessions[session.id] = session
        sessionOrder.append(session.id)
        activeSessionID = session.id
        openWindowHandler?(session.id)
        return session
    }

    func dataset(for path: String?) -> DatasetMeta? {
        guard let path else { return nil }
        return datasets.first { $0.filePath == path }
    }

    func variable(named name: String?, inDataset path: String?) -> VarMeta? {
        guard let name, let ds = dataset(for: path) else { return nil }
        return ds.variables.first { $0.name == name }
    }

    func handleIncomingURLs(_ urls: [URL]) {
        let valid = urls.filter(\.isFileURL)
        guard !valid.isEmpty else { return }
        if openWindowHandler == nil {
            pendingLaunchURLs.append(contentsOf: valid)
            return
        }
        Task {
            await openFiles(valid)
        }
    }

    func flushPendingLaunchURLsIfReady() {
        guard openWindowHandler != nil, !pendingLaunchURLs.isEmpty else { return }
        let urls = pendingLaunchURLs
        pendingLaunchURLs.removeAll()
        Task {
            await openFiles(urls)
        }
    }

    func openFileDialog(in sessionID: UUID? = nil) {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = true
        panel.title = "Open Datasets"
        panel.message = "Select NetCDF, HDF, or GMT Grid files"
        panel.allowedContentTypes = FileAssociationManager.supportedExtensions.compactMap {
            FileAssociationManager.utType(forExtension: $0)
        }
        guard panel.runModal() == .OK else { return }
        let urls = panel.urls
        Task {
            await openFiles(urls, preferredSessionID: sessionID)
        }
    }

    func openFiles(_ urls: [URL], preferredSessionID: UUID? = nil) async {
        await ensureBackendConfigured()
        for (index, url) in urls.enumerated() {
            let standardized = url.standardizedFileURL
            NSDocumentController.shared.noteNewRecentDocumentURL(standardized)
            do {
                let meta: DatasetMeta
                if let existing = datasets.first(where: { $0.filePath == standardized.path }) {
                    meta = existing
                } else {
                    meta = try await rpc.openDataset(path: standardized.path)
                    datasets.append(meta)
                }

                let targetSession: PlotSession
                if index == 0,
                   let sid = preferredSessionID ?? activeSessionID,
                   let current = sessions[sid],
                   current.datasetPath == nil {
                    targetSession = current
                } else if index == 0,
                          let sid = preferredSessionID,
                          let current = sessions[sid],
                          urls.count == 1,
                          current.datasetPath == meta.filePath {
                    targetSession = current
                } else {
                    targetSession = spawnNewTab(from: NSApp.keyWindow)
                }

                let shouldAutoPlot: Bool = {
                    switch environment.datasetOpenBehavior {
                    case .alwaysPlot:
                        return !meta.plotableVariables.isEmpty
                    case .smart:
                        return meta.plotableVariables.count == 1
                    case .inspectOnly:
                        return false
                    }
                }()

                if shouldAutoPlot, let firstVar = meta.plotableVariables.first {
                    await selectVariable(
                        datasetPath: meta.filePath,
                        varName: firstVar.name,
                        inSession: targetSession.id,
                        openInNewTab: false
                    )
                } else {
                    targetSession.inspectedTarget = .dataset(meta.filePath)
                    targetSession.selectedInspectorTab = .info
                    if targetSession.currentRender == nil {
                        targetSession.datasetPath = nil
                        targetSession.variableName = nil
                        targetSession.config = nil
                        targetSession.hoverGrid = nil
                        targetSession.regionHistory = RegionHistoryStack()
                    }
                    if meta.plotableVariables.isEmpty {
                        targetSession.statusText = "No regular 2D grid found; inspect metadata in Info."
                    } else {
                        targetSession.statusText = "\(meta.plotableVariables.count) plottable variables · Double-click to plot"
                    }
                }
            } catch {
                if let sid = preferredSessionID ?? activeSessionID, let session = sessions[sid] {
                    session.errorMessage = "Failed to open \(standardized.lastPathComponent): \(error.localizedDescription)"
                } else {
                    backendError = error.localizedDescription
                }
            }
        }
    }

    func inspectDataset(path: String, inSession sessionID: UUID, switchToInfoTab: Bool = true) {
        let target = session(for: sessionID)
        let nextTarget: InspectTarget = .dataset(path)
        if target.inspectedTarget != nextTarget {
            target.inspectedTarget = nextTarget
        }
        if switchToInfoTab && target.selectedInspectorTab != .info {
            target.selectedInspectorTab = .info
        }
    }

    func inspectGroup(datasetPath: String, isPlotable: Bool, inSession sessionID: UUID, switchToInfoTab: Bool = true) {
        let target = session(for: sessionID)
        let nextTarget: InspectTarget = .group(datasetPath: datasetPath, isPlotable: isPlotable)
        if target.inspectedTarget != nextTarget {
            target.inspectedTarget = nextTarget
        }
        if switchToInfoTab && target.selectedInspectorTab != .info {
            target.selectedInspectorTab = .info
        }
    }

    func inspectVariable(datasetPath: String, varName: String, inSession sessionID: UUID, switchToInfoTab: Bool = true) {
        let target = session(for: sessionID)
        let nextTarget: InspectTarget = .variable(datasetPath: datasetPath, variableName: varName)
        if target.inspectedTarget != nextTarget {
            target.inspectedTarget = nextTarget
        }
        if switchToInfoTab && target.selectedInspectorTab != .info {
            target.selectedInspectorTab = .info
        }
    }

    func openStructureSheet(datasetPath: String, inSession sessionID: UUID) {
        let target = session(for: sessionID)
        target.structureSheetDatasetPath = datasetPath
    }

    func selectVariable(
        datasetPath: String,
        varName: String,
        inSession sessionID: UUID,
        openInNewTab: Bool
    ) async {
        guard let ds = dataset(for: datasetPath),
              let variable = ds.variables.first(where: { $0.name == varName }) else {
            return
        }

        let target: PlotSession = openInNewTab ? spawnNewTab(from: NSApp.keyWindow) : session(for: sessionID)
        target.inspectedTarget = .variable(datasetPath: ds.filePath, variableName: variable.name)

        guard variable.is2DPlotable else {
            target.selectedInspectorTab = .info
            target.statusText = variable.unsupportedReason.isEmpty ? "Variable is not a 2D plotable grid." : variable.unsupportedReason
            return
        }

        target.datasetPath = ds.filePath
        target.variableName = variable.name

        if target.selectedInspectorTab == .info {
            target.selectedInspectorTab = .map
        }

        var cfg = PlotConfig.defaultConfig(
            for: variable,
            dataset: ds,
            previewLOD: environment.defaultPreviewLOD,
            previewDPI: environment.defaultPreviewDPI
        )
        cfg.cnBorderDir = environment.cnBorderDirOverride

        if variable.isGeographic {
            if let options = try? await rpc.recommendProjections(
                region: cfg.region,
                varName: variable.name,
                varAttrs: variable.attrsDictionary,
                isGeographic: true
            ) {
                target.recommendedProjections = options
                if let first = options.first {
                    cfg.projection = first.code
                }
            }
        } else {
            target.recommendedProjections = [ProjectionOption(label: "Cartesian linear", code: "X16c/10c", category: "Linear")]
            cfg.projection = "X16c/10c"
            cfg.projectionMode = "manual"
        }

        target.config = cfg
        target.regionHistory.reset(root: RegionEntry(
            label: "Full Grid",
            region: cfg.region,
            projection: cfg.projection,
            projectionMode: cfg.projectionMode,
            title: cfg.title
        ))
        await target.renderNow()
    }

    func applySubregion(
        inSession sessionID: UUID,
        region: [Double],
        label: String? = nil,
        explicitProjection: String? = nil,
        openInNewTab: Bool
    ) async {
        let source = session(for: sessionID)
        guard var baseConfig = source.config, region.count == 4 else { return }

        let varMeta = variable(named: baseConfig.variableName, inDataset: baseConfig.sourcePath)
        var nextProjection = baseConfig.projection
        var nextMode = baseConfig.projectionMode

        if let explicitProjection {
            nextProjection = explicitProjection
            nextMode = "manual"
        } else if baseConfig.projectionMode == "auto" || baseConfig.projection == "IntMollOcean" {
            if baseConfig.isGeographic {
                if let options = try? await rpc.recommendProjections(
                    region: region,
                    varName: baseConfig.variableName,
                    varAttrs: varMeta?.attrsDictionary ?? ["description": baseConfig.variableDescription],
                    isGeographic: true
                ), let first = options.first {
                    nextProjection = first.code
                }
                nextMode = "auto"
            } else {
                nextProjection = "X16c/10c"
                nextMode = "manual"
            }
        }

        let entryLabel = label ?? RegionEntry.formatRegionLabel(region, isGeographic: baseConfig.isGeographic)
        let titleBase = varMeta?.displayTitle ?? baseConfig.variableName
        let nextTitle = "\(titleBase) [\(entryLabel)]"

        baseConfig.region = region
        baseConfig.projection = nextProjection
        baseConfig.projectionMode = nextMode
        baseConfig.title = nextTitle

        if openInNewTab {
            let newSession = spawnNewTab(from: NSApp.keyWindow)
            newSession.datasetPath = source.datasetPath
            newSession.variableName = source.variableName
            newSession.config = baseConfig
            let rootEntry: RegionEntry = {
                if let first = source.regionHistory.entries.first {
                    return RegionEntry(
                        label: first.label,
                        region: first.region,
                        projection: first.projection,
                        projectionMode: first.projectionMode,
                        title: first.title
                    )
                }
                let fullRegion: [Double]? = {
                    if let x = varMeta?.xRange, let y = varMeta?.yRange, x.count == 2, y.count == 2 {
                        return [x[0], x[1], y[0], y[1]]
                    }
                    return nil
                }()
                return RegionEntry(
                    label: "Full Grid",
                    region: fullRegion,
                    projection: baseConfig.projection,
                    projectionMode: baseConfig.projectionMode,
                    title: titleBase
                )
            }()
            newSession.regionHistory.reset(root: rootEntry)
            newSession.regionHistory.push(RegionEntry(
                label: entryLabel,
                region: region,
                projection: nextProjection,
                projectionMode: nextMode,
                title: nextTitle
            ))
            await newSession.refreshRecommendations()
            await newSession.renderNow()
        } else {
            source.config = baseConfig
            source.regionHistory.push(RegionEntry(
                label: entryLabel,
                region: region,
                projection: nextProjection,
                projectionMode: nextMode,
                title: nextTitle
            ))
            await source.refreshRecommendations()
            await source.renderNow()
        }
    }

    func handleBoxSelection(
        inSession sessionID: UUID,
        u0: Double,
        v0: Double,
        u1: Double,
        v1: Double,
        forceNewTab: Bool
    ) async {
        let source = session(for: sessionID)
        guard let render = source.currentRender,
              let region = render.resolvedConfig.region,
              let dims = render.dimsCm else {
            source.statusText = "Render a plot before selecting a region."
            return
        }
        do {
            let selected = try await rpc.selectionRegion(
                u0: u0,
                v0: v0,
                u1: u1,
                v1: v1,
                region: region,
                projection: render.resolvedConfig.projection,
                dimsCm: dims,
                gmtConf: render.resolvedConfig.gmtConf
            )
            guard let selected else {
                source.statusText = "Selection contains no valid map area."
                return
            }
            source.interactionMode = .pan
            let newTab = forceNewTab || environment.boxSelectOpensNewTab
            await applySubregion(inSession: sessionID, region: selected, openInNewTab: newTab)
        } catch {
            source.errorMessage = error.localizedDescription
        }
    }

    func scanRange(inSession sessionID: UUID, symmetric: Bool) async {
        let target = session(for: sessionID)
        guard let cfg = target.config else { return }
        target.isScanningRange = true
        target.statusText = "Scanning data range…"
        defer { target.isScanningRange = false }
        do {
            let res = try await rpc.scanRange(
                sourcePath: cfg.sourcePath,
                variableName: cfg.variableName,
                sliceIndices: cfg.sliceIndices,
                region: cfg.region,
                maskMode: cfg.maskMode,
                symmetric: symmetric
            )
            var lo = res.zMin
            var hi = res.zMax
            if lo >= hi {
                lo -= 1.0
                hi += 1.0
            }
            target.config?.cptRange = [lo, hi]
            target.config?.symmetricCpt = symmetric
            target.statusText = String(format: "Range: %.4g to %.4g", lo, hi)
            await target.renderNow()
        } catch {
            target.errorMessage = error.localizedDescription
            target.statusText = "Range scan failed"
        }
    }

    func exportImage(for sessionID: UUID) {
        let target = session(for: sessionID)
        guard let cfg = target.config else { return }
        let panel = NSSavePanel()
        panel.title = "Export Publication Image"
        panel.nameFieldStringValue = "\(cfg.variableName.isEmpty ? "map" : cfg.variableName).png"
        panel.allowedContentTypes = [.png, .pdf, .svg, .tiff]
        panel.allowsOtherFileTypes = false
        guard panel.runModal() == .OK, let url = panel.url else { return }

        var exportConfig = cfg
        exportConfig.preview = false
        exportConfig.dpi = max(300, cfg.dpi)
        target.statusText = "Exporting \(url.lastPathComponent)…"

        Task {
            do {
                _ = try await rpc.render(
                    config: exportConfig,
                    outputPath: url.path,
                    isExport: true,
                    includeHover: false
                )
                target.statusText = "Exported \(url.lastPathComponent)"
            } catch {
                target.errorMessage = "Export failed: \(error.localizedDescription)"
            }
        }
    }

    func exportScript(for sessionID: UUID) {
        let target = session(for: sessionID)
        guard let cfg = target.config else { return }
        let panel = NSSavePanel()
        panel.title = "Export GMT Bash Script"
        panel.nameFieldStringValue = "\(cfg.variableName.isEmpty ? "plot" : cfg.variableName).sh"
        panel.allowedContentTypes = [.shellScript]
        guard panel.runModal() == .OK, let url = panel.url else { return }

        Task {
            do {
                let script = try await rpc.generateScript(config: cfg, outputFilename: "\(cfg.variableName).png")
                try script.write(to: url, atomically: true, encoding: .utf8)
                try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
                target.statusText = "Saved script \(url.lastPathComponent)"
            } catch {
                target.errorMessage = "Failed to export script: \(error.localizedDescription)"
            }
        }
    }

    func closeDataset(path: String) {
        datasets.removeAll { $0.filePath == path }
        for sid in sessionOrder {
            guard let s = sessions[sid] else { continue }
            if s.inspectedTarget?.datasetPath == path {
                s.inspectedTarget = nil
            }
            if s.structureSheetDatasetPath == path {
                s.structureSheetDatasetPath = nil
            }
            if s.datasetPath == path {
                s.datasetPath = nil
                s.variableName = nil
                s.config = nil
                s.currentRender = nil
                s.hoverGrid = nil
                s.regionHistory = RegionHistoryStack()
                s.statusText = "Dataset closed"
            }
        }
    }
}
