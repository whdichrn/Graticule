import AppKit
import SwiftUI
import UniformTypeIdentifiers

struct WorkspaceWindowView: View {
    @Environment(\.openWindow) private var openWindow

    let sessionID: UUID
    @ObservedObject var workspace: WorkspaceManager
    @ObservedObject var session: PlotSession

    @State private var columnVisibility: NavigationSplitViewVisibility = .all
    @State private var showInspector = true
    @State private var showScriptSheet = false
    @State private var isDropTargeted = false

    init(sessionID: UUID, workspace: WorkspaceManager = .shared) {
        self.sessionID = sessionID
        self.workspace = workspace
        self.session = workspace.session(for: sessionID)
    }

    var body: some View {
        NavigationSplitView(columnVisibility: $columnVisibility) {
            DatasetSidebarView(workspace: workspace, session: session)
                .navigationSplitViewColumnWidth(min: 205, ideal: 235, max: 320)
        } detail: {
            PlotCanvasContainerView(workspace: workspace, session: session)
        }
        .adaptiveInspector(isPresented: $showInspector) {
            PlotInspectorView(workspace: workspace, session: session)
        }
        .navigationTitle(windowTitle)
        .navigationSubtitle(windowSubtitle)
        .toolbar {
            ToolbarItemGroup(placement: .principal) {
                Picker("Mode", selection: $session.interactionMode) {
                    Image(systemName: "hand.raised")
                        .tag(InteractionMode.pan)
                        .help("Pan Mode (drag to move, Shift-drag to box-select)")
                    Image(systemName: "rectangle.dashed")
                        .tag(InteractionMode.select)
                        .help("Select Mode (drag a box to drill down; hold Option for new tab)")
                }
                .pickerStyle(.segmented)
                .frame(width: 78)

                Menu {
                    Section("Arctic (North Pole)") {
                        Button("Arctic Ocean (60°N–90°N)") {
                            spawnPolar(w: 0, e: 360, s: 60, n: 90, proj: "S0/90/15c", label: "Arctic 60N–90N", newTab: false)
                        }
                        Button("High Arctic (75°N–90°N)") {
                            spawnPolar(w: 0, e: 360, s: 75, n: 90, proj: "S0/90/15c", label: "High Arctic 75N–90N", newTab: false)
                        }
                    }
                    Section("Antarctic (South Pole)") {
                        Button("Antarctic Ocean (60°S–90°S)") {
                            spawnPolar(w: 0, e: 360, s: -90, n: -60, proj: "S0/-90/15c", label: "Antarctic 60S–90S", newTab: false)
                        }
                        Button("High Antarctic (75°S–90°S)") {
                            spawnPolar(w: 0, e: 360, s: -90, n: -75, proj: "S0/-90/15c", label: "High Antarctic 75S–90S", newTab: false)
                        }
                    }
                    Divider()
                    Menu("Open in New Tab") {
                        Button("Arctic Ocean (60°N–90°N)") {
                            spawnPolar(w: 0, e: 360, s: 60, n: 90, proj: "S0/90/15c", label: "Arctic 60N–90N", newTab: true)
                        }
                        Button("Antarctic Ocean (60°S–90°S)") {
                            spawnPolar(w: 0, e: 360, s: -90, n: -60, proj: "S0/-90/15c", label: "Antarctic 60S–90S", newTab: true)
                        }
                    }
                } label: {
                    Label {
                        Text("Polar")
                    } icon: {
                        Image(nsImage: PolarGraticuleIcon.toolbarImage)
                            .renderingMode(.template)
                    }
                }
                .disabled(session.config == nil)
                .help("Polar stereographic presets")

                Button {
                    session.fitRequestToken += 1
                } label: {
                    Label("Fit", systemImage: "arrow.up.left.and.arrow.down.right")
                }
                .disabled(session.currentRender == nil)
                .help("Fit map to window (⌘0)")

                Button {
                    session.actualSizeRequestToken += 1
                } label: {
                    Label("1:1", systemImage: "1.magnifyingglass")
                }
                .disabled(session.currentRender == nil)
                .help("Actual size 100% (⌘1)")

                Button {
                    Task { await session.renderNow() }
                } label: {
                    if session.isRendering {
                        Label {
                            Text("Render")
                        } icon: {
                            ProgressView()
                                .controlSize(.small)
                        }
                    } else {
                        Label("Render", systemImage: "arrow.clockwise")
                    }
                }
                .disabled(session.config == nil)
                .help("Re-render active plot (⌘R)")
            }

            ToolbarItemGroup(placement: .primaryAction) {
                Button {
                    showScriptSheet = true
                } label: {
                    Label("Script", systemImage: "terminal")
                }
                .disabled(session.config == nil)
                .help("Inspect or edit GMT script (⌘E)")

                Button {
                    workspace.exportImage(for: session.id)
                } label: {
                    Label("Export", systemImage: "square.and.arrow.up")
                }
                .disabled(session.config == nil)
                .help("Export publication image (⇧⌘E)")

                Button {
                    showInspector.toggle()
                } label: {
                    Label("Inspector", systemImage: "sidebar.right")
                }
                .help("Toggle Inspector (⌥⌘I)")
            }
        }
        .background(WindowTabBridge(session: session, workspace: workspace))
        .onDrop(of: [.fileURL], isTargeted: $isDropTargeted) { providers in
            handleDrop(providers: providers)
        }
        .overlay {
            if isDropTargeted {
                RoundedRectangle(cornerRadius: 12)
                    .stroke(Color.accentColor, style: StrokeStyle(lineWidth: 3, dash: [8, 6]))
                    .background(Color.accentColor.opacity(0.06))
                    .padding(8)
                    .allowsHitTesting(false)
            }
        }
        .sheet(isPresented: $showScriptSheet) {
            ScriptEditorSheet(workspace: workspace, session: session)
        }
        .focusedSceneValue(\.activeSessionID, sessionID)
        .onReceive(NotificationCenter.default.publisher(for: .graticuleCommand)) { note in
            handleCommandNotification(note)
        }
        .task {
            workspace.openWindowHandler = { nextID in
                openWindow(id: "workspace", value: nextID)
            }
            await workspace.ensureBackendConfigured()
            workspace.flushPendingLaunchURLsIfReady()
        }
    }

    private var windowTitle: String {
        if let varName = session.variableName, let path = session.datasetPath {
            let fileName = URL(fileURLWithPath: path).lastPathComponent
            if session.regionHistory.isDrilledDown, let label = session.regionHistory.current?.label {
                return "\(varName) · \(label)"
            }
            return "\(fileName) — \(varName)"
        }
        return "Graticule"
    }

    private var windowSubtitle: String {
        if let proj = session.config?.projection {
            return "-J\(proj)"
        }
        return ""
    }

    private func spawnPolar(w: Double, e: Double, s: Double, n: Double, proj: String, label: String, newTab: Bool) {
        Task {
            await workspace.applySubregion(
                inSession: session.id,
                region: [w, e, s, n],
                label: label,
                explicitProjection: proj,
                openInNewTab: newTab || workspace.environment.boxSelectOpensNewTab
            )
        }
    }

    private func handleDrop(providers: [NSItemProvider]) -> Bool {
        var accepted = false
        for provider in providers where provider.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier) {
            accepted = true
            provider.loadItem(forTypeIdentifier: UTType.fileURL.identifier, options: nil) { item, _ in
                guard let data = item as? Data,
                      let url = URL(dataRepresentation: data, relativeTo: nil) else {
                    return
                }
                Task { @MainActor in
                    await workspace.openFiles([url], preferredSessionID: session.id)
                }
            }
        }
        return accepted
    }

    private func handleCommandNotification(_ note: Notification) {
        guard let targetID = note.userInfo?["sessionID"] as? UUID, targetID == sessionID,
              let cmd = note.userInfo?["command"] as? AppCommandKind else {
            return
        }
        switch cmd {
        case .openDataset:
            workspace.openFileDialog(in: sessionID)
        case .exportImage:
            workspace.exportImage(for: sessionID)
        case .exportScript:
            workspace.exportScript(for: sessionID)
        case .openScriptEditor:
            if session.config != nil { showScriptSheet = true }
        case .fitWindow:
            session.fitRequestToken += 1
        case .actualSize:
            session.actualSizeRequestToken += 1
        case .refresh:
            Task { await session.renderNow() }
        case .back:
            Task { await session.navigateBack() }
        case .forward:
            Task { await session.navigateForward() }
        case .fullExtent:
            Task { await session.resetRegionToFullExtent() }
        case .toggleInspector:
            showInspector.toggle()
        case .panMode:
            session.interactionMode = .pan
        case .selectMode:
            session.interactionMode = .select
        }
    }
}

private struct WindowTabBridge: NSViewRepresentable {
    let session: PlotSession
    let workspace: WorkspaceManager

    final class Coordinator: NSObject {
        weak var observedWindow: NSWindow?
        let sessionID: UUID
        var didConfigureToolbar = false

        init(sessionID: UUID) {
            self.sessionID = sessionID
        }

        @objc func windowDidBecomeKey(_ note: Notification) {
            let sid = sessionID
            Task { @MainActor in
                WorkspaceManager.shared.activeSessionID = sid
            }
        }

        @objc func windowWillClose(_ note: Notification) {
            let sid = sessionID
            Task { @MainActor in
                WorkspaceManager.shared.unregisterSession(id: sid)
            }
        }

        deinit {
            NotificationCenter.default.removeObserver(self)
        }
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(sessionID: session.id)
    }

    func makeNSView(context: Context) -> NSView {
        let view = NSView(frame: .zero)
        DispatchQueue.main.async {
            attachIfNeeded(view: view, coordinator: context.coordinator)
        }
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        DispatchQueue.main.async {
            attachIfNeeded(view: nsView, coordinator: context.coordinator)
        }
    }

    @MainActor
    private func attachIfNeeded(view: NSView, coordinator: Coordinator) {
        guard let window = view.window else { return }
        window.tabbingMode = .preferred
        window.tabbingIdentifier = "GraticuleWorkspace"

        if !coordinator.didConfigureToolbar, let toolbar = window.toolbar {
            toolbar.displayMode = .iconAndLabel
            coordinator.didConfigureToolbar = true
        }

        if coordinator.observedWindow !== window {
            NotificationCenter.default.removeObserver(coordinator)
            coordinator.observedWindow = window
            NotificationCenter.default.addObserver(
                coordinator,
                selector: #selector(Coordinator.windowDidBecomeKey(_:)),
                name: NSWindow.didBecomeKeyNotification,
                object: window
            )
            NotificationCenter.default.addObserver(
                coordinator,
                selector: #selector(Coordinator.windowWillClose(_:)),
                name: NSWindow.willCloseNotification,
                object: window
            )
        }

        if let parentID = session.parentWindowIDForTabbing {
            session.parentWindowIDForTabbing = nil
            if let parentWindow = NSApp.windows.first(where: { ObjectIdentifier($0) == parentID && $0 !== window && $0.isVisible }) {
                parentWindow.addTabbedWindow(window, ordered: .above)
                window.makeKeyAndOrderFront(nil)
            }
        }
    }
}

@MainActor
private enum PolarGraticuleIcon {
    static let toolbarImage: NSImage = {
        let size = NSSize(width: 16, height: 16)
        let image = NSImage(size: size, flipped: false) { rect in
            let center = CGPoint(x: rect.midX, y: rect.midY)
            let outerR: CGFloat = 6.2
            let innerR: CGFloat = 3.1

            NSColor.labelColor.setStroke()
            NSColor.labelColor.setFill()

            let outerCircle = NSBezierPath(
                ovalIn: CGRect(x: center.x - outerR, y: center.y - outerR, width: outerR * 2, height: outerR * 2)
            )
            outerCircle.lineWidth = 1.25
            outerCircle.stroke()

            let innerCircle = NSBezierPath(
                ovalIn: CGRect(x: center.x - innerR, y: center.y - innerR, width: innerR * 2, height: innerR * 2)
            )
            innerCircle.lineWidth = 0.9
            innerCircle.stroke()

            let meridians = NSBezierPath()
            meridians.lineWidth = 0.9
            meridians.move(to: CGPoint(x: center.x - outerR, y: center.y))
            meridians.line(to: CGPoint(x: center.x + outerR, y: center.y))
            meridians.move(to: CGPoint(x: center.x, y: center.y - outerR))
            meridians.line(to: CGPoint(x: center.x, y: center.y + outerR))
            meridians.stroke()

            let diag = NSBezierPath()
            diag.lineWidth = 0.75
            let invSqrt2: CGFloat = 1.0 / sqrt(2.0)
            for sx in [-1.0, 1.0] as [CGFloat] {
                for sy in [-1.0, 1.0] as [CGFloat] {
                    diag.move(to: CGPoint(x: center.x + sx * innerR * invSqrt2, y: center.y + sy * innerR * invSqrt2))
                    diag.line(to: CGPoint(x: center.x + sx * outerR * invSqrt2, y: center.y + sy * outerR * invSqrt2))
                }
            }
            diag.stroke()

            let poleDot = NSBezierPath(
                ovalIn: CGRect(x: center.x - 1.05, y: center.y - 1.05, width: 2.1, height: 2.1)
            )
            poleDot.fill()
            return true
        }
        image.isTemplate = true
        return image
    }()
}
