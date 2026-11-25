import AppKit
import SwiftUI

struct DatasetSidebarView: View {
    @ObservedObject var workspace: WorkspaceManager
    @ObservedObject var session: PlotSession

    @State private var searchText = ""

    var body: some View {
        VStack(spacing: 0) {
            if !workspace.datasets.isEmpty {
                HStack(spacing: 6) {
                    Image(systemName: "magnifyingglass")
                        .foregroundStyle(.secondary)
                        .font(.caption)
                    TextField("Filter variables…", text: $searchText)
                        .textFieldStyle(.plain)
                        .font(.subheadline)
                    if !searchText.isEmpty {
                        Button {
                            searchText = ""
                        } label: {
                            Image(systemName: "xmark.circle.fill")
                                .foregroundStyle(.secondary)
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 6)
                .background(.quaternary.opacity(0.45), in: RoundedRectangle(cornerRadius: 7))
                .padding(.horizontal, 10)
                .padding(.top, 8)
                .padding(.bottom, 6)
            }

            if workspace.datasets.isEmpty {
                AdaptiveEmptyState(
                    "No Datasets",
                    systemImage: "doc.badge.plus",
                    description: "Open or drop .nc / .grd / .npz files to explore."
                )
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                NativeDatasetOutlineView(
                    workspace: workspace,
                    session: session,
                    datasets: workspace.datasets,
                    searchText: searchText,
                    inspectedTarget: session.inspectedTarget,
                    plottedDatasetPath: session.datasetPath,
                    plottedVariableName: session.variableName
                )
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }

            Divider()

            HStack {
                Button {
                    workspace.openFileDialog(in: session.id)
                } label: {
                    Label("Open Dataset…", systemImage: "plus")
                }
                .buttonStyle(.borderless)
                .font(.subheadline)
                Spacer()
                if !workspace.datasets.isEmpty {
                    Text("\(workspace.datasets.count) file\(workspace.datasets.count == 1 ? "" : "s")")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
        }
    }
}

private final class OutlineNode: NSObject {
    enum Kind {
        case dataset(DatasetMeta)
        case group(datasetPath: String, isPlotableGroup: Bool, title: String)
        case variable(dataset: DatasetMeta, variable: VarMeta)
    }

    let id: String
    var kind: Kind
    var children: [OutlineNode] = []

    init(id: String, kind: Kind) {
        self.id = id
        self.kind = kind
    }

    var target: InspectTarget? {
        switch kind {
        case .dataset(let ds):
            return .dataset(ds.filePath)
        case .group(let path, let isPlotableGroup, _):
            return .group(datasetPath: path, isPlotable: isPlotableGroup)
        case .variable(let ds, let v):
            return .variable(datasetPath: ds.filePath, variableName: v.name)
        }
    }
}

private final class KeyHandlingOutlineView: NSOutlineView {
    var onReturnPressed: (() -> Void)?

    override func keyDown(with event: NSEvent) {
        if event.keyCode == 36 || event.keyCode == 76 {
            onReturnPressed?()
            return
        }
        super.keyDown(with: event)
    }
}

private final class SidebarOutlineCellView: NSTableCellView {
    static let reuseIdentifier = NSUserInterfaceItemIdentifier("SidebarOutlineCell")

    private let iconImageView = NSImageView()
    private let titleField = NSTextField(labelWithString: "")
    private let plottedDotView = NSView()
    private let detailField = NSTextField(labelWithString: "")

    private var isGroup = false
    private var isDataset = false
    private var isPlotable = false
    private var isPlotted = false

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        setupViews()
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        setupViews()
    }

    override var backgroundStyle: NSView.BackgroundStyle {
        didSet {
            applyColors()
        }
    }

    private func setupViews() {
        iconImageView.translatesAutoresizingMaskIntoConstraints = false
        iconImageView.imageScaling = .scaleProportionallyDown

        titleField.translatesAutoresizingMaskIntoConstraints = false
        titleField.lineBreakMode = .byTruncatingTail
        titleField.maximumNumberOfLines = 1
        titleField.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        titleField.setContentHuggingPriority(.defaultLow, for: .horizontal)

        plottedDotView.translatesAutoresizingMaskIntoConstraints = false
        plottedDotView.wantsLayer = true
        plottedDotView.layer?.cornerRadius = 3
        plottedDotView.isHidden = true

        detailField.translatesAutoresizingMaskIntoConstraints = false
        detailField.lineBreakMode = .byTruncatingMiddle
        detailField.maximumNumberOfLines = 1
        detailField.alignment = .right
        detailField.font = .monospacedDigitSystemFont(ofSize: 11, weight: .regular)
        detailField.setContentCompressionResistancePriority(.required, for: .horizontal)
        detailField.setContentHuggingPriority(.required, for: .horizontal)

        addSubview(iconImageView)
        addSubview(titleField)
        addSubview(plottedDotView)
        addSubview(detailField)

        NSLayoutConstraint.activate([
            iconImageView.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 4),
            iconImageView.centerYAnchor.constraint(equalTo: centerYAnchor),
            iconImageView.widthAnchor.constraint(equalToConstant: 15),
            iconImageView.heightAnchor.constraint(equalToConstant: 15),

            titleField.leadingAnchor.constraint(equalTo: iconImageView.trailingAnchor, constant: 6),
            titleField.centerYAnchor.constraint(equalTo: centerYAnchor),

            plottedDotView.leadingAnchor.constraint(equalTo: titleField.trailingAnchor, constant: 5),
            plottedDotView.centerYAnchor.constraint(equalTo: centerYAnchor),
            plottedDotView.widthAnchor.constraint(equalToConstant: 6),
            plottedDotView.heightAnchor.constraint(equalToConstant: 6),

            detailField.leadingAnchor.constraint(greaterThanOrEqualTo: plottedDotView.trailingAnchor, constant: 8),
            detailField.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -6),
            detailField.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
    }

    func configure(
        symbolName: String,
        title: String,
        detail: String,
        isGroup: Bool,
        isDataset: Bool,
        isPlotable: Bool,
        isPlotted: Bool,
        tooltip: String?
    ) {
        self.isGroup = isGroup
        self.isDataset = isDataset
        self.isPlotable = isPlotable
        self.isPlotted = isPlotted

        iconImageView.image = NSImage(systemSymbolName: symbolName, accessibilityDescription: nil)
        iconImageView.symbolConfiguration = NSImage.SymbolConfiguration(
            pointSize: isGroup ? 11 : 12.5,
            weight: (isDataset || isPlotted) ? .medium : .regular
        )

        titleField.stringValue = title
        if isGroup {
            titleField.font = .systemFont(ofSize: 11.5, weight: .medium)
        } else if isDataset {
            titleField.font = .systemFont(ofSize: 13, weight: .medium)
        } else {
            titleField.font = .systemFont(ofSize: 13, weight: isPlotted ? .semibold : .regular)
        }

        detailField.stringValue = detail
        detailField.isHidden = detail.isEmpty
        plottedDotView.isHidden = !isPlotted
        self.toolTip = tooltip

        applyColors()
    }

    private func applyColors() {
        let emphasized = (backgroundStyle == .emphasized)
        if emphasized {
            titleField.textColor = .white
            detailField.textColor = NSColor.white.withAlphaComponent(0.85)
            iconImageView.contentTintColor = .white
            plottedDotView.layer?.backgroundColor = NSColor.white.cgColor
        } else {
            if isGroup {
                titleField.textColor = .secondaryLabelColor
                iconImageView.contentTintColor = .secondaryLabelColor
            } else if isDataset {
                titleField.textColor = .labelColor
                iconImageView.contentTintColor = .secondaryLabelColor
            } else {
                titleField.textColor = isPlotable ? .labelColor : .secondaryLabelColor
                iconImageView.contentTintColor = isPlotted ? .controlAccentColor : (isPlotable ? .labelColor : .secondaryLabelColor)
            }
            detailField.textColor = .secondaryLabelColor
            plottedDotView.layer?.backgroundColor = NSColor.controlAccentColor.cgColor
        }
    }
}

private struct NativeDatasetOutlineView: NSViewRepresentable {
    let workspace: WorkspaceManager
    let session: PlotSession
    let datasets: [DatasetMeta]
    let searchText: String
    let inspectedTarget: InspectTarget?
    let plottedDatasetPath: String?
    let plottedVariableName: String?

    func makeCoordinator() -> Coordinator {
        Coordinator(workspace: workspace, session: session)
    }

    func makeNSView(context: Context) -> NSScrollView {
        let scrollView = NSScrollView()
        scrollView.borderType = .noBorder
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = false
        scrollView.autohidesScrollers = true
        scrollView.drawsBackground = false

        let outlineView = KeyHandlingOutlineView()
        outlineView.headerView = nil
        outlineView.style = .inset
        outlineView.usesAlternatingRowBackgroundColors = true
        outlineView.rowHeight = 26
        outlineView.intercellSpacing = NSSize(width: 0, height: 2)
        outlineView.indentationPerLevel = 14
        outlineView.allowsMultipleSelection = false
        outlineView.allowsEmptySelection = true
        outlineView.focusRingType = .none
        outlineView.columnAutoresizingStyle = .firstColumnOnlyAutoresizingStyle

        let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("MainColumn"))
        column.resizingMask = .autoresizingMask
        outlineView.addTableColumn(column)
        outlineView.outlineTableColumn = column

        let coordinator = context.coordinator
        coordinator.outlineView = outlineView
        outlineView.dataSource = coordinator
        outlineView.delegate = coordinator
        outlineView.target = coordinator
        outlineView.doubleAction = #selector(Coordinator.handleDoubleClick(_:))
        outlineView.onReturnPressed = { [weak coordinator] in
            coordinator?.handleReturnKey()
        }

        let menu = NSMenu()
        menu.delegate = coordinator
        outlineView.menu = menu

        scrollView.documentView = outlineView
        coordinator.update(
            datasets: datasets,
            searchText: searchText,
            inspectedTarget: inspectedTarget,
            plottedDatasetPath: plottedDatasetPath,
            plottedVariableName: plottedVariableName
        )
        return scrollView
    }

    func updateNSView(_ nsView: NSScrollView, context: Context) {
        context.coordinator.update(
            datasets: datasets,
            searchText: searchText,
            inspectedTarget: inspectedTarget,
            plottedDatasetPath: plottedDatasetPath,
            plottedVariableName: plottedVariableName
        )
    }

    @MainActor
    final class Coordinator: NSObject, NSOutlineViewDataSource, NSOutlineViewDelegate, NSMenuDelegate {
        let workspace: WorkspaceManager
        let session: PlotSession
        weak var outlineView: KeyHandlingOutlineView?

        private var rootNodes: [OutlineNode] = []
        private var nodeCache: [String: OutlineNode] = [:]

        private var collapsedDatasetIDs: Set<String> = []
        private var collapsedPlotGroupIDs: Set<String> = []
        private var expandedOtherGroupIDs: Set<String> = []

        private var currentQuery = ""
        private var lastStructuralSignature = ""
        private var lastPlottedKey = ""
        private var isSyncingExpansion = false
        private var isSyncingSelection = false

        init(workspace: WorkspaceManager, session: PlotSession) {
            self.workspace = workspace
            self.session = session
        }

        func update(
            datasets: [DatasetMeta],
            searchText: String,
            inspectedTarget: InspectTarget?,
            plottedDatasetPath: String?,
            plottedVariableName: String?
        ) {
            guard let outlineView else { return }

            let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            currentQuery = query

            let structuralSig = query + "|" + datasets.map { "\($0.filePath):\($0.variables.count)" }.joined(separator: ";")
            let plottedKey = "\(plottedDatasetPath ?? "")::\(plottedVariableName ?? "")"

            if structuralSig != lastStructuralSignature {
                lastStructuralSignature = structuralSig
                lastPlottedKey = plottedKey
                rebuildTree(datasets: datasets, query: query)
                outlineView.reloadData()
                applyExpansionState()
                syncSelectionFromSwiftUI(inspectedTarget)
            } else {
                if plottedKey != lastPlottedKey {
                    lastPlottedKey = plottedKey
                    refreshVisibleRows()
                }
                syncSelectionFromSwiftUI(inspectedTarget)
            }
        }

        private func cachedNode(id: String, kind: OutlineNode.Kind) -> OutlineNode {
            if let existing = nodeCache[id] {
                existing.kind = kind
                return existing
            }
            let created = OutlineNode(id: id, kind: kind)
            nodeCache[id] = created
            return created
        }

        private func rebuildTree(datasets: [DatasetMeta], query: String) {
            var nextRoots: [OutlineNode] = []
            var seenIDs: Set<String> = []

            for dataset in datasets {
                let plotables = dataset.plotableVariables.filter { matches($0, query: query) }
                let nonPlotables = dataset.nonPlotableVariables.filter { matches($0, query: query) }
                let matchesFile = query.isEmpty || !plotables.isEmpty || !nonPlotables.isEmpty || dataset.fileName.lowercased().contains(query)
                guard matchesFile else { continue }

                let dsID = "ds:\(dataset.filePath)"
                seenIDs.insert(dsID)
                let dsNode = cachedNode(id: dsID, kind: .dataset(dataset))
                var dsChildren: [OutlineNode] = []

                if !plotables.isEmpty {
                    let grpID = "grp:plot:\(dataset.filePath)"
                    seenIDs.insert(grpID)
                    let grpNode = cachedNode(
                        id: grpID,
                        kind: .group(datasetPath: dataset.filePath, isPlotableGroup: true, title: "Plottable Grids (\(plotables.count))")
                    )
                    grpNode.children = plotables.map { variable in
                        let vID = "var:\(dataset.filePath)::\(variable.name)"
                        seenIDs.insert(vID)
                        let node = cachedNode(id: vID, kind: .variable(dataset: dataset, variable: variable))
                        node.children = []
                        return node
                    }
                    dsChildren.append(grpNode)
                }

                if !nonPlotables.isEmpty {
                    let grpID = "grp:other:\(dataset.filePath)"
                    seenIDs.insert(grpID)
                    let grpNode = cachedNode(
                        id: grpID,
                        kind: .group(datasetPath: dataset.filePath, isPlotableGroup: false, title: "Coordinates & Other (\(nonPlotables.count))")
                    )
                    grpNode.children = nonPlotables.map { variable in
                        let vID = "var:\(dataset.filePath)::\(variable.name)"
                        seenIDs.insert(vID)
                        let node = cachedNode(id: vID, kind: .variable(dataset: dataset, variable: variable))
                        node.children = []
                        return node
                    }
                    dsChildren.append(grpNode)
                }

                dsNode.children = dsChildren
                nextRoots.append(dsNode)
            }

            rootNodes = nextRoots
            nodeCache = nodeCache.filter { seenIDs.contains($0.key) }
        }

        private func applyExpansionState() {
            guard let outlineView else { return }
            isSyncingExpansion = true
            defer { isSyncingExpansion = false }

            let forceExpand = !currentQuery.isEmpty
            for dsNode in rootNodes {
                let dsExpanded = forceExpand || !collapsedDatasetIDs.contains(dsNode.id)
                if dsExpanded {
                    outlineView.expandItem(dsNode)
                } else {
                    outlineView.collapseItem(dsNode)
                }
                for grpNode in dsNode.children {
                    if case .group(_, let isPlotableGroup, _) = grpNode.kind {
                        let grpExpanded: Bool = forceExpand || (
                            isPlotableGroup
                                ? !collapsedPlotGroupIDs.contains(grpNode.id)
                                : expandedOtherGroupIDs.contains(grpNode.id)
                        )
                        if grpExpanded {
                            outlineView.expandItem(grpNode)
                        } else {
                            outlineView.collapseItem(grpNode)
                        }
                    }
                }
            }
        }

        private func refreshVisibleRows() {
            guard let outlineView, outlineView.numberOfRows > 0 else { return }
            let rows = IndexSet(0..<outlineView.numberOfRows)
            let cols = IndexSet(integer: 0)
            outlineView.reloadData(forRowIndexes: rows, columnIndexes: cols)
        }

        private func syncSelectionFromSwiftUI(_ target: InspectTarget?) {
            guard let outlineView else { return }
            let desiredNode = findNode(for: target)
            let desiredRow = desiredNode.map { outlineView.row(forItem: $0) } ?? -1
            if outlineView.selectedRow == desiredRow {
                return
            }
            isSyncingSelection = true
            defer { isSyncingSelection = false }
            if desiredRow >= 0 {
                outlineView.selectRowIndexes(IndexSet(integer: desiredRow), byExtendingSelection: false)
                outlineView.scrollRowToVisible(desiredRow)
            } else if target == nil {
                outlineView.deselectAll(nil)
            }
        }

        private func findNode(for target: InspectTarget?) -> OutlineNode? {
            guard let target else { return nil }
            switch target {
            case .dataset(let path):
                return nodeCache["ds:\(path)"]
            case .group(let path, let isPlotable):
                return nodeCache["grp:\(isPlotable ? "plot" : "other"):\(path)"]
            case .variable(let path, let name):
                return nodeCache["var:\(path)::\(name)"]
            }
        }

        // MARK: - NSOutlineViewDataSource

        func outlineView(_ outlineView: NSOutlineView, numberOfChildrenOfItem item: Any?) -> Int {
            guard let node = item as? OutlineNode else {
                return rootNodes.count
            }
            return node.children.count
        }

        func outlineView(_ outlineView: NSOutlineView, child index: Int, ofItem item: Any?) -> Any {
            guard let node = item as? OutlineNode else {
                return rootNodes[index]
            }
            return node.children[index]
        }

        func outlineView(_ outlineView: NSOutlineView, isItemExpandable item: Any) -> Bool {
            guard let node = item as? OutlineNode else { return false }
            return !node.children.isEmpty
        }

        // MARK: - NSOutlineViewDelegate

        func outlineView(_ outlineView: NSOutlineView, shouldSelectItem item: Any) -> Bool {
            item is OutlineNode
        }

        func outlineView(_ outlineView: NSOutlineView, viewFor tableColumn: NSTableColumn?, item: Any) -> NSView? {
            guard let node = item as? OutlineNode else { return nil }
            let cell = (outlineView.makeView(withIdentifier: SidebarOutlineCellView.reuseIdentifier, owner: nil) as? SidebarOutlineCellView)
                ?? SidebarOutlineCellView()
            cell.identifier = SidebarOutlineCellView.reuseIdentifier

            switch node.kind {
            case .dataset(let dataset):
                cell.configure(
                    symbolName: "doc.text",
                    title: dataset.fileName,
                    detail: "\(dataset.variables.count) vars",
                    isGroup: false,
                    isDataset: true,
                    isPlotable: false,
                    isPlotted: false,
                    tooltip: dataset.filePath
                )
            case .group(_, let isPlotableGroup, let title):
                cell.configure(
                    symbolName: isPlotableGroup ? "square.grid.2x2" : "slider.horizontal.2.square",
                    title: title,
                    detail: "",
                    isGroup: true,
                    isDataset: false,
                    isPlotable: false,
                    isPlotted: false,
                    tooltip: nil
                )
            case .variable(let dataset, let variable):
                let isPlotted = (session.datasetPath == dataset.filePath && session.variableName == variable.name)
                let tip = variable.unsupportedReason.isEmpty
                    ? "\(variable.displayTitle) (Double-click to plot)"
                    : variable.unsupportedReason
                cell.configure(
                    symbolName: iconName(for: variable),
                    title: variable.name,
                    detail: inlineSummary(for: variable),
                    isGroup: false,
                    isDataset: false,
                    isPlotable: variable.is2DPlotable,
                    isPlotted: isPlotted,
                    tooltip: tip
                )
            }
            return cell
        }

        func outlineViewSelectionDidChange(_ notification: Notification) {
            guard !isSyncingSelection, let outlineView else { return }
            let row = outlineView.selectedRow
            guard row >= 0, let node = outlineView.item(atRow: row) as? OutlineNode else { return }
            let kind = node.kind
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                switch kind {
                case .dataset(let dataset):
                    self.workspace.inspectDataset(path: dataset.filePath, inSession: self.session.id, switchToInfoTab: true)
                case .group(let datasetPath, let isPlotableGroup, _):
                    self.workspace.inspectGroup(datasetPath: datasetPath, isPlotable: isPlotableGroup, inSession: self.session.id, switchToInfoTab: true)
                case .variable(let dataset, let variable):
                    self.workspace.inspectVariable(
                        datasetPath: dataset.filePath,
                        varName: variable.name,
                        inSession: self.session.id,
                        switchToInfoTab: true
                    )
                }
            }
        }

        func outlineViewItemDidExpand(_ notification: Notification) {
            guard !isSyncingExpansion, currentQuery.isEmpty,
                  let node = notification.userInfo?["NSObject"] as? OutlineNode else {
                return
            }
            switch node.kind {
            case .dataset:
                collapsedDatasetIDs.remove(node.id)
            case .group(_, let isPlotableGroup, _):
                if isPlotableGroup {
                    collapsedPlotGroupIDs.remove(node.id)
                } else {
                    expandedOtherGroupIDs.insert(node.id)
                }
            case .variable:
                break
            }
        }

        func outlineViewItemDidCollapse(_ notification: Notification) {
            guard !isSyncingExpansion, currentQuery.isEmpty,
                  let node = notification.userInfo?["NSObject"] as? OutlineNode else {
                return
            }
            switch node.kind {
            case .dataset:
                collapsedDatasetIDs.insert(node.id)
            case .group(_, let isPlotableGroup, _):
                if isPlotableGroup {
                    collapsedPlotGroupIDs.insert(node.id)
                } else {
                    expandedOtherGroupIDs.remove(node.id)
                }
            case .variable:
                break
            }
        }

        // MARK: - Actions

        @objc func handleDoubleClick(_ sender: Any?) {
            guard let outlineView else { return }
            let row = outlineView.clickedRow >= 0 ? outlineView.clickedRow : outlineView.selectedRow
            guard row >= 0, let node = outlineView.item(atRow: row) as? OutlineNode else { return }
            activateNode(node, openInNewTab: NSEvent.modifierFlags.contains(.command), toggleExpandOnContainers: true)
        }

        func handleReturnKey() {
            guard let outlineView else { return }
            let row = outlineView.selectedRow
            guard row >= 0, let node = outlineView.item(atRow: row) as? OutlineNode else { return }
            activateNode(node, openInNewTab: NSEvent.modifierFlags.contains(.command), toggleExpandOnContainers: false)
        }

        private func activateNode(_ node: OutlineNode, openInNewTab: Bool, toggleExpandOnContainers: Bool) {
            guard let outlineView else { return }
            switch node.kind {
            case .variable(let dataset, let variable):
                if variable.is2DPlotable {
                    Task {
                        await workspace.selectVariable(
                            datasetPath: dataset.filePath,
                            varName: variable.name,
                            inSession: session.id,
                            openInNewTab: openInNewTab
                        )
                    }
                } else {
                    workspace.inspectVariable(
                        datasetPath: dataset.filePath,
                        varName: variable.name,
                        inSession: session.id,
                        switchToInfoTab: true
                    )
                }
            case .dataset, .group:
                if toggleExpandOnContainers {
                    if outlineView.isItemExpanded(node) {
                        outlineView.collapseItem(node)
                    } else {
                        outlineView.expandItem(node)
                    }
                }
            }
        }

        // MARK: - Context Menu

        func menuNeedsUpdate(_ menu: NSMenu) {
            menu.removeAllItems()
            guard let outlineView else { return }
            let row = outlineView.clickedRow
            guard row >= 0, let node = outlineView.item(atRow: row) as? OutlineNode else { return }

            if outlineView.selectedRow != row {
                outlineView.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
            }

            switch node.kind {
            case .dataset(let dataset):
                let inspectItem = NSMenuItem(title: "Inspect File Info", action: #selector(menuInspectDataset(_:)), keyEquivalent: "")
                inspectItem.target = self
                inspectItem.representedObject = dataset.filePath
                menu.addItem(inspectItem)

                let cdlItem = NSMenuItem(title: "CDL (ncdump -h)…", action: #selector(menuShowCDL(_:)), keyEquivalent: "")
                cdlItem.target = self
                cdlItem.representedObject = dataset.filePath
                menu.addItem(cdlItem)

                menu.addItem(.separator())

                let finderItem = NSMenuItem(title: "Reveal in Finder", action: #selector(menuRevealInFinder(_:)), keyEquivalent: "")
                finderItem.target = self
                finderItem.representedObject = dataset.filePath
                menu.addItem(finderItem)

                menu.addItem(.separator())

                let closeItem = NSMenuItem(title: "Close Dataset", action: #selector(menuCloseDataset(_:)), keyEquivalent: "")
                closeItem.target = self
                closeItem.representedObject = dataset.filePath
                menu.addItem(closeItem)

            case .variable(let dataset, let variable):
                let ctx = VariableMenuContext(datasetPath: dataset.filePath, variableName: variable.name)
                if variable.is2DPlotable {
                    let plotItem = NSMenuItem(title: "Plot in Active Tab", action: #selector(menuPlotActiveTab(_:)), keyEquivalent: "")
                    plotItem.target = self
                    plotItem.representedObject = ctx
                    menu.addItem(plotItem)

                    let newTabItem = NSMenuItem(title: "Open in New Tab", action: #selector(menuPlotNewTab(_:)), keyEquivalent: "")
                    newTabItem.target = self
                    newTabItem.representedObject = ctx
                    menu.addItem(newTabItem)

                    menu.addItem(.separator())
                }

                let inspectItem = NSMenuItem(title: "Inspect Info", action: #selector(menuInspectVariable(_:)), keyEquivalent: "")
                inspectItem.target = self
                inspectItem.representedObject = ctx
                menu.addItem(inspectItem)

                let cdlItem = NSMenuItem(title: "CDL (ncdump -h)…", action: #selector(menuShowCDL(_:)), keyEquivalent: "")
                cdlItem.target = self
                cdlItem.representedObject = dataset.filePath
                menu.addItem(cdlItem)

                menu.addItem(.separator())

                let closeItem = NSMenuItem(title: "Close Dataset", action: #selector(menuCloseDataset(_:)), keyEquivalent: "")
                closeItem.target = self
                closeItem.representedObject = dataset.filePath
                menu.addItem(closeItem)

            case .group(let datasetPath, _, _):
                let cdlItem = NSMenuItem(title: "CDL (ncdump -h)…", action: #selector(menuShowCDL(_:)), keyEquivalent: "")
                cdlItem.target = self
                cdlItem.representedObject = datasetPath
                menu.addItem(cdlItem)
            }
        }

        @objc private func menuInspectDataset(_ sender: NSMenuItem) {
            guard let path = sender.representedObject as? String else { return }
            workspace.inspectDataset(path: path, inSession: session.id, switchToInfoTab: true)
        }

        @objc private func menuInspectVariable(_ sender: NSMenuItem) {
            guard let ctx = sender.representedObject as? VariableMenuContext else { return }
            workspace.inspectVariable(datasetPath: ctx.datasetPath, varName: ctx.variableName, inSession: session.id, switchToInfoTab: true)
        }

        @objc private func menuPlotActiveTab(_ sender: NSMenuItem) {
            guard let ctx = sender.representedObject as? VariableMenuContext else { return }
            Task {
                await workspace.selectVariable(datasetPath: ctx.datasetPath, varName: ctx.variableName, inSession: session.id, openInNewTab: false)
            }
        }

        @objc private func menuPlotNewTab(_ sender: NSMenuItem) {
            guard let ctx = sender.representedObject as? VariableMenuContext else { return }
            Task {
                await workspace.selectVariable(datasetPath: ctx.datasetPath, varName: ctx.variableName, inSession: session.id, openInNewTab: true)
            }
        }

        @objc private func menuShowCDL(_ sender: NSMenuItem) {
            guard let path = sender.representedObject as? String else { return }
            workspace.openStructureSheet(datasetPath: path, inSession: session.id)
        }

        @objc private func menuRevealInFinder(_ sender: NSMenuItem) {
            guard let path = sender.representedObject as? String else { return }
            NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: path)])
        }

        @objc private func menuCloseDataset(_ sender: NSMenuItem) {
            guard let path = sender.representedObject as? String else { return }
            workspace.closeDataset(path: path)
        }

        // MARK: - Helpers

        private func matches(_ variable: VarMeta, query: String) -> Bool {
            guard !query.isEmpty else { return true }
            if variable.name.lowercased().contains(query) || variable.displayTitle.lowercased().contains(query) {
                return true
            }
            return variable.attrs.contains {
                $0.key.lowercased().contains(query) || $0.value.lowercased().contains(query)
            }
        }

        private func iconName(for variable: VarMeta) -> String {
            guard variable.is2DPlotable else {
                return variable.dimensions.count == 1 ? "ruler" : "slider.horizontal.2.square"
            }
            if variable.isCategorical {
                return "square.grid.3x3.topleft.filled"
            }
            if !variable.sliceDims.isEmpty {
                return "square.stack.3d.up"
            }
            return variable.isGeographic ? "map" : "squareshape.split.3x3"
        }

        private func inlineSummary(for variable: VarMeta) -> String {
            if variable.shape.isEmpty {
                return variable.dtype.isEmpty ? "scalar" : variable.dtype
            }
            let shapeText = variable.shape.map(String.init).joined(separator: "×")
            if variable.isCategorical && !variable.flagValues.isEmpty {
                return "\(shapeText) · \(variable.flagValues.count) flags"
            }
            let unit = variable.units.trimmingCharacters(in: .whitespacesAndNewlines)
            if unit.isEmpty || (variable.isCategorical && ["1", "none", "unitless", "-"].contains(unit.lowercased())) {
                return shapeText
            }
            return "\(shapeText) · \(unit)"
        }
    }
}

private final class VariableMenuContext: NSObject {
    let datasetPath: String
    let variableName: String

    init(datasetPath: String, variableName: String) {
        self.datasetPath = datasetPath
        self.variableName = variableName
    }
}

private extension OutlineNode.Kind {
    var isGroupNode: Bool {
        if case .group = self { return true }
        return false
    }
}
