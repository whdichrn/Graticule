import AppKit
import SwiftUI

struct DatasetSidebarView: View {
    @Bindable var workspace: WorkspaceManager
    let session: PlotSession

    @State private var searchText = ""
    @State private var expandedNonGridDatasets: Set<String> = []

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

            List {
                if workspace.datasets.isEmpty {
                    ContentUnavailableView {
                        Label("No Datasets", systemImage: "doc.badge.plus")
                    } description: {
                        Text("Open or drop .nc / .grd files to explore.")
                    }
                    .listRowSeparator(.hidden)
                } else {
                    ForEach(workspace.datasets) { dataset in
                        datasetSection(dataset)
                    }
                }
            }
            .listStyle(.sidebar)

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

    @ViewBuilder
    private func datasetSection(_ dataset: DatasetMeta) -> some View {
        let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let plotables = dataset.plotableVariables.filter {
            query.isEmpty || $0.name.lowercased().contains(query) || $0.displayTitle.lowercased().contains(query)
        }
        let nonPlotables = dataset.nonPlotableVariables.filter {
            query.isEmpty || $0.name.lowercased().contains(query) || $0.displayTitle.lowercased().contains(query)
        }

        Section {
            ForEach(plotables) { variable in
                variableRow(dataset: dataset, variable: variable, isPlotable: true)
            }

            if !nonPlotables.isEmpty {
                DisclosureGroup(
                    isExpanded: Binding(
                        get: { !query.isEmpty || expandedNonGridDatasets.contains(dataset.filePath) },
                        set: { expanded in
                            if expanded {
                                expandedNonGridDatasets.insert(dataset.filePath)
                            } else {
                                expandedNonGridDatasets.remove(dataset.filePath)
                            }
                        }
                    )
                ) {
                    ForEach(nonPlotables) { variable in
                        variableRow(dataset: dataset, variable: variable, isPlotable: false)
                    }
                } label: {
                    Text("Other Variables (\(nonPlotables.count))")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        } header: {
            HStack(spacing: 6) {
                Image(systemName: "doc.text")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Text(dataset.fileName)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .help(dataset.filePath)
                Spacer()
            }
            .contextMenu {
                Button("Reveal in Finder") {
                    NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: dataset.filePath)])
                }
                Divider()
                Button("Close Dataset", role: .destructive) {
                    workspace.closeDataset(path: dataset.filePath)
                }
            }
        }
    }

    @ViewBuilder
    private func variableRow(dataset: DatasetMeta, variable: VarMeta, isPlotable: Bool) -> some View {
        let isSelected = session.datasetPath == dataset.filePath && session.variableName == variable.name
        Button {
            let cmdPressed = NSEvent.modifierFlags.contains(.command)
            Task {
                await workspace.selectVariable(
                    datasetPath: dataset.filePath,
                    varName: variable.name,
                    inSession: session.id,
                    openInNewTab: cmdPressed && isPlotable
                )
            }
        } label: {
            HStack(spacing: 8) {
                Image(systemName: isPlotable ? (variable.sliceDims.isEmpty ? "map" : "square.stack.3d.up") : "slider.horizontal.2.square")
                    .font(.caption)
                    .foregroundStyle(isSelected ? Color.accentColor : (isPlotable ? .primary : .secondary))
                    .frame(width: 14)

                VStack(alignment: .leading, spacing: 1) {
                    Text(variable.name)
                        .font(.body)
                        .fontWeight(isSelected ? .semibold : .regular)
                        .foregroundStyle(isPlotable ? .primary : .secondary)
                        .lineLimit(1)

                    Text(subtitle(for: variable))
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                Spacer(minLength: 0)
            }
            .padding(.vertical, 2)
            .padding(.horizontal, 4)
            .contentShape(Rectangle())
            .background(
                RoundedRectangle(cornerRadius: 6)
                    .fill(isSelected ? Color.accentColor.opacity(0.14) : Color.clear)
            )
        }
        .buttonStyle(.plain)
        .help(variable.unsupportedReason.isEmpty ? variable.displayTitle : variable.unsupportedReason)
        .contextMenu {
            Button("Inspect Info") {
                workspace.inspectVariable(
                    datasetPath: dataset.filePath,
                    varName: variable.name,
                    inSession: session.id
                )
            }
            if isPlotable {
                Divider()
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
            Button("Close Dataset", role: .destructive) {
                workspace.closeDataset(path: dataset.filePath)
            }
        }
    }

    private func subtitle(for variable: VarMeta) -> String {
        if variable.units.isEmpty {
            return "[\(variable.shapeSummary)]"
        }
        return "[\(variable.shapeSummary)] · \(variable.units)"
    }
}
