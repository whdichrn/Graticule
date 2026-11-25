import AppKit
import SwiftUI

struct DatasetSidebarView: View {
    @ObservedObject var workspace: WorkspaceManager
    @ObservedObject var session: PlotSession

    @State private var searchText = ""
    @State private var collapsedDatasets: Set<String> = []
    @State private var collapsedPlotableGroups: Set<String> = []
    @State private var expandedOtherGroups: Set<String> = []

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
                .padding(.bottom, 4)
            }

            if workspace.datasets.isEmpty {
                List {
                    AdaptiveEmptyState(
                        "No Datasets",
                        systemImage: "doc.badge.plus",
                        description: "Open or drop .nc / .grd / .npz files to explore."
                    )
                    .listRowSeparator(.hidden)
                }
                .listStyle(.sidebar)
            } else {
                List(selection: selectionBinding) {
                    ForEach(workspace.datasets) { dataset in
                        datasetTree(dataset)
                    }
                }
                .listStyle(.sidebar)
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

    private var selectionBinding: Binding<InspectTarget?> {
        Binding(
            get: { session.inspectedTarget },
            set: { newTarget in
                guard let newTarget else { return }
                switch newTarget {
                case .dataset(let path):
                    workspace.inspectDataset(path: path, inSession: session.id, switchToInfoTab: true)
                case .variable(let path, let name):
                    workspace.inspectVariable(datasetPath: path, varName: name, inSession: session.id, switchToInfoTab: true)
                }
            }
        )
    }

    @ViewBuilder
    private func datasetTree(_ dataset: DatasetMeta) -> some View {
        let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let plotables = dataset.plotableVariables.filter { matches($0, query: query) }
        let nonPlotables = dataset.nonPlotableVariables.filter { matches($0, query: query) }

        if query.isEmpty || !plotables.isEmpty || !nonPlotables.isEmpty || dataset.fileName.lowercased().contains(query) {
            DisclosureGroup(
                isExpanded: Binding(
                    get: { !query.isEmpty || !collapsedDatasets.contains(dataset.filePath) },
                    set: { expanded in
                        if expanded {
                            collapsedDatasets.remove(dataset.filePath)
                        } else {
                            collapsedDatasets.insert(dataset.filePath)
                        }
                    }
                )
            ) {
                if !plotables.isEmpty {
                    DisclosureGroup(
                        isExpanded: Binding(
                            get: { !query.isEmpty || !collapsedPlotableGroups.contains(dataset.filePath) },
                            set: { expanded in
                                if expanded {
                                    collapsedPlotableGroups.remove(dataset.filePath)
                                } else {
                                    collapsedPlotableGroups.insert(dataset.filePath)
                                }
                            }
                        )
                    ) {
                        ForEach(plotables) { variable in
                            variableRow(dataset: dataset, variable: variable, isPlotable: true)
                                .tag(InspectTarget.variable(datasetPath: dataset.filePath, variableName: variable.name))
                        }
                    } label: {
                        HStack(spacing: 6) {
                            Image(systemName: "square.grid.2x2")
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                            Text("Plottable Grids (\(plotables.count))")
                                .font(.caption.weight(.medium))
                                .foregroundStyle(.secondary)
                        }
                    }
                }

                if !nonPlotables.isEmpty {
                    DisclosureGroup(
                        isExpanded: Binding(
                            get: { !query.isEmpty || expandedOtherGroups.contains(dataset.filePath) },
                            set: { expanded in
                                if expanded {
                                    expandedOtherGroups.insert(dataset.filePath)
                                } else {
                                    expandedOtherGroups.remove(dataset.filePath)
                                }
                            }
                        )
                    ) {
                        ForEach(nonPlotables) { variable in
                            variableRow(dataset: dataset, variable: variable, isPlotable: false)
                                .tag(InspectTarget.variable(datasetPath: dataset.filePath, variableName: variable.name))
                        }
                    } label: {
                        HStack(spacing: 6) {
                            Image(systemName: "slider.horizontal.2.square")
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                            Text("Coordinates & Other (\(nonPlotables.count))")
                                .font(.caption.weight(.medium))
                                .foregroundStyle(.secondary)
                        }
                    }
                }
            } label: {
                datasetHeaderRow(dataset)
            }
            .tag(InspectTarget.dataset(dataset.filePath))
        }
    }

    @ViewBuilder
    private func datasetHeaderRow(_ dataset: DatasetMeta) -> some View {
        HStack(spacing: 6) {
            Image(systemName: "doc.text")
                .font(.caption)
                .foregroundStyle(.secondary)
            Text(dataset.fileName)
                .font(.subheadline.weight(.medium))
                .lineLimit(1)
                .truncationMode(.middle)
                .help(dataset.filePath)
            Spacer(minLength: 4)
            Text("\(dataset.variables.count)")
                .font(.caption2.monospacedDigit())
                .foregroundStyle(.secondary)
                .padding(.horizontal, 5)
                .padding(.vertical, 1)
                .background(.quaternary.opacity(0.6), in: Capsule())

            Button {
                workspace.openStructureSheet(datasetPath: dataset.filePath, inSession: session.id)
            } label: {
                Image(systemName: "list.bullet.rectangle")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.borderless)
            .help("Show File Structure (CDL)")
        }
        .contentShape(Rectangle())
        .contextMenu {
            Button("Inspect File Info") {
                workspace.inspectDataset(path: dataset.filePath, inSession: session.id, switchToInfoTab: true)
            }
            Button("Show Structure (CDL)…") {
                workspace.openStructureSheet(datasetPath: dataset.filePath, inSession: session.id)
            }
            Divider()
            Button("Reveal in Finder") {
                NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: dataset.filePath)])
            }
            Divider()
            Button("Close Dataset", role: .destructive) {
                workspace.closeDataset(path: dataset.filePath)
            }
        }
    }

    @ViewBuilder
    private func variableRow(dataset: DatasetMeta, variable: VarMeta, isPlotable: Bool) -> some View {
        let isPlotted = session.datasetPath == dataset.filePath && session.variableName == variable.name
        HStack(spacing: 8) {
            Image(systemName: iconName(for: variable, isPlotable: isPlotable))
                .font(.caption)
                .foregroundStyle(isPlotted ? Color.accentColor : (isPlotable ? .primary : .secondary))
                .frame(width: 14)

            VStack(alignment: .leading, spacing: 1) {
                HStack(spacing: 5) {
                    Text(variable.name)
                        .font(.body)
                        .fontWeight(isPlotted ? .semibold : .regular)
                        .foregroundStyle(isPlotable ? .primary : .secondary)
                        .lineLimit(1)
                    if isPlotted {
                        Circle()
                            .fill(Color.accentColor)
                            .frame(width: 5, height: 5)
                    }
                }

                Text(subtitle(for: variable))
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }

            Spacer(minLength: 4)

            if isPlotable {
                Button {
                    let cmdPressed = NSEvent.modifierFlags.contains(.command)
                    Task {
                        await workspace.selectVariable(
                            datasetPath: dataset.filePath,
                            varName: variable.name,
                            inSession: session.id,
                            openInNewTab: cmdPressed
                        )
                    }
                } label: {
                    Image(systemName: isPlotted ? "arrow.clockwise.circle" : "play.fill")
                        .font(.caption)
                        .foregroundStyle(isPlotted ? Color.accentColor : .secondary)
                }
                .buttonStyle(.borderless)
                .help("Plot \(variable.name) (⌘-click for new tab)")
            }
        }
        .padding(.vertical, 2)
        .contentShape(Rectangle())
        .simultaneousGesture(
            TapGesture(count: 2).onEnded {
                guard isPlotable else { return }
                let cmdPressed = NSEvent.modifierFlags.contains(.command)
                Task {
                    await workspace.selectVariable(
                        datasetPath: dataset.filePath,
                        varName: variable.name,
                        inSession: session.id,
                        openInNewTab: cmdPressed
                    )
                }
            }
        )
        .help(variable.unsupportedReason.isEmpty ? "\(variable.displayTitle) (Double-click to plot)" : variable.unsupportedReason)
        .contextMenu {
            if isPlotable {
                Button("Plot in Active Tab") {
                    Task {
                        await workspace.selectVariable(
                            datasetPath: dataset.filePath,
                            varName: variable.name,
                            inSession: session.id,
                            openInNewTab: false
                        )
                    }
                }
                Button("Open in New Tab") {
                    Task {
                        await workspace.selectVariable(
                            datasetPath: dataset.filePath,
                            varName: variable.name,
                            inSession: session.id,
                            openInNewTab: true
                        )
                    }
                }
                Divider()
            }
            Button("Inspect Info") {
                workspace.inspectVariable(
                    datasetPath: dataset.filePath,
                    varName: variable.name,
                    inSession: session.id,
                    switchToInfoTab: true
                )
            }
            Button("Show File Structure (CDL)…") {
                workspace.openStructureSheet(datasetPath: dataset.filePath, inSession: session.id)
            }
            Divider()
            Button("Close Dataset", role: .destructive) {
                workspace.closeDataset(path: dataset.filePath)
            }
        }
    }

    private func matches(_ variable: VarMeta, query: String) -> Bool {
        guard !query.isEmpty else { return true }
        if variable.name.lowercased().contains(query) || variable.displayTitle.lowercased().contains(query) {
            return true
        }
        return variable.attrs.contains {
            $0.key.lowercased().contains(query) || $0.value.lowercased().contains(query)
        }
    }

    private func iconName(for variable: VarMeta, isPlotable: Bool) -> String {
        guard isPlotable else {
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

    private func subtitle(for variable: VarMeta) -> String {
        var parts = ["[\(variable.shapeSummary)]"]
        if variable.isCategorical && !variable.flagValues.isEmpty {
            parts.append("\(variable.flagValues.count) flags")
        } else if !variable.units.isEmpty {
            parts.append(variable.units)
        }
        return parts.joined(separator: " · ")
    }
}
