import AppKit
import SwiftUI

struct DatasetStructureSheet: View {
    enum DisplayMode: String, CaseIterable, Identifiable {
        case structured = "Structured"
        case cdl = "CDL (ncdump -h)"

        var id: String { rawValue }
    }

    @ObservedObject var workspace: WorkspaceManager
    @ObservedObject var session: PlotSession
    let datasetPath: String

    @Environment(\.dismiss) private var dismiss
    @State private var mode: DisplayMode = .structured
    @State private var searchText = ""
    @State private var didCopy = false

    private var dataset: DatasetMeta? {
        workspace.dataset(for: datasetPath)
    }

    var body: some View {
        VStack(spacing: 0) {
            if let dataset {
                headerView(for: dataset)
                Divider()

                switch mode {
                case .structured:
                    structuredContent(for: dataset)
                case .cdl:
                    cdlContent(for: dataset)
                }
            } else {
                AdaptiveEmptyState(
                    "Dataset Closed",
                    systemImage: "doc.questionmark",
                    description: "The inspected file is no longer loaded."
                )
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .frame(minWidth: 700, idealWidth: 780, minHeight: 520, idealHeight: 620)
    }

    @ViewBuilder
    private func headerView(for dataset: DatasetMeta) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .top, spacing: 12) {
                VStack(alignment: .leading, spacing: 3) {
                    Text(dataset.fileName)
                        .font(.title3.weight(.semibold))
                    Text(dataset.filePath)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                        .lineLimit(2)
                }
                Spacer()
                Text("\(dataset.dimensions.count) dims · \(dataset.variables.count) vars")
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
                    .padding(.top, 2)

                Button {
                    let pasteboard = NSPasteboard.general
                    pasteboard.clearContents()
                    pasteboard.setString(dataset.cdlSummary(), forType: .string)
                    didCopy = true
                    Task {
                        try? await Task.sleep(for: .seconds(1.5))
                        didCopy = false
                    }
                } label: {
                    Label(didCopy ? "Copied" : "Copy CDL", systemImage: didCopy ? "checkmark" : "doc.on.doc")
                }
                .controlSize(.small)

                Button("Done") {
                    session.structureSheetDatasetPath = nil
                    dismiss()
                }
                .keyboardShortcut(.cancelAction)
                .controlSize(.small)
            }

            HStack(spacing: 10) {
                Picker("View", selection: $mode) {
                    ForEach(DisplayMode.allCases) { item in
                        Text(item.rawValue).tag(item)
                    }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .frame(width: 240)

                HStack(spacing: 6) {
                    Image(systemName: "magnifyingglass")
                        .foregroundStyle(.secondary)
                        .font(.caption)
                    TextField("Filter variables or attributes…", text: $searchText)
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
                .padding(.horizontal, 8)
                .padding(.vertical, 5)
                .background(.quaternary.opacity(0.45), in: RoundedRectangle(cornerRadius: 6))
            }
        }
        .padding(16)
    }

    @ViewBuilder
    private func structuredContent(for dataset: DatasetMeta) -> some View {
        let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let filteredVars = dataset.variables.filter { matchesVariable($0, query: query) }
        let filteredGlobals = dataset.globalAttrs.filter {
            query.isEmpty || $0.key.lowercased().contains(query) || $0.value.lowercased().contains(query)
        }

        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                if !dataset.dimensions.isEmpty {
                    VStack(alignment: .leading, spacing: 6) {
                        Text("Dimensions")
                            .font(.headline)
                        ScrollView(.horizontal, showsIndicators: false) {
                            HStack(spacing: 8) {
                                ForEach(dataset.dimensions.keys.sorted(), id: \.self) { dim in
                                    Text("\(dim) = \(dataset.dimensions[dim] ?? 0)")
                                        .font(.caption.monospacedDigit())
                                        .padding(.horizontal, 8)
                                        .padding(.vertical, 4)
                                        .background(.quaternary.opacity(0.55), in: Capsule())
                                }
                            }
                        }
                    }
                }

                VStack(alignment: .leading, spacing: 8) {
                    Text("Variables (\(filteredVars.count))")
                        .font(.headline)
                    ForEach(filteredVars) { variable in
                        VStack(alignment: .leading, spacing: 6) {
                            HStack(spacing: 8) {
                                Text("\(variable.dtype) \(variable.name)(\(variable.dimensions.joined(separator: ", ")))")
                                    .font(.system(.subheadline, design: .monospaced).weight(.semibold))
                                Text("[\(variable.shapeSummary)]")
                                    .font(.caption.monospacedDigit())
                                    .foregroundStyle(.secondary)
                                if variable.isCategorical {
                                    Text("categorical")
                                        .font(.caption2.weight(.medium))
                                        .padding(.horizontal, 6)
                                        .padding(.vertical, 1)
                                        .background(Color.accentColor.opacity(0.14), in: Capsule())
                                        .foregroundStyle(Color.accentColor)
                                }
                                Spacer()
                                Button("Info") {
                                    workspace.inspectVariable(
                                        datasetPath: dataset.filePath,
                                        varName: variable.name,
                                        inSession: session.id,
                                        switchToInfoTab: true
                                    )
                                    session.structureSheetDatasetPath = nil
                                    dismiss()
                                }
                                .buttonStyle(.bordered)
                                .controlSize(.small)

                                if variable.is2DPlotable {
                                    Button("Plot") {
                                        session.structureSheetDatasetPath = nil
                                        dismiss()
                                        Task {
                                            await workspace.selectVariable(
                                                datasetPath: dataset.filePath,
                                                varName: variable.name,
                                                inSession: session.id,
                                                openInNewTab: false
                                            )
                                        }
                                    }
                                    .buttonStyle(.borderedProminent)
                                    .controlSize(.small)
                                }
                            }

                            if !variable.attrs.isEmpty {
                                VStack(alignment: .leading, spacing: 3) {
                                    ForEach(variable.attrs) { attr in
                                        HStack(alignment: .top, spacing: 8) {
                                            Text(":\(attr.key)")
                                                .font(.system(.caption, design: .monospaced).weight(.medium))
                                                .foregroundStyle(.secondary)
                                                .frame(width: 140, alignment: .leading)
                                            Text(attr.value)
                                                .font(.system(.caption, design: .monospaced))
                                                .textSelection(.enabled)
                                                .frame(maxWidth: .infinity, alignment: .leading)
                                        }
                                    }
                                }
                                .padding(.leading, 8)
                            }
                        }
                        .padding(10)
                        .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 8))
                        .overlay(
                            RoundedRectangle(cornerRadius: 8)
                                .stroke(Color.primary.opacity(0.08), lineWidth: 1)
                        )
                    }
                }

                if !filteredGlobals.isEmpty {
                    VStack(alignment: .leading, spacing: 6) {
                        Text("Global Attributes (\(filteredGlobals.count))")
                            .font(.headline)
                        VStack(alignment: .leading, spacing: 4) {
                            ForEach(filteredGlobals) { attr in
                                HStack(alignment: .top, spacing: 8) {
                                    Text(":\(attr.key)")
                                        .font(.system(.caption, design: .monospaced).weight(.medium))
                                        .foregroundStyle(.secondary)
                                        .frame(width: 160, alignment: .leading)
                                    Text(attr.value)
                                        .font(.system(.caption, design: .monospaced))
                                        .textSelection(.enabled)
                                        .frame(maxWidth: .infinity, alignment: .leading)
                                }
                            }
                        }
                        .padding(10)
                        .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 8))
                        .overlay(
                            RoundedRectangle(cornerRadius: 8)
                                .stroke(Color.primary.opacity(0.08), lineWidth: 1)
                        )
                    }
                }
            }
            .padding(16)
        }
    }

    @ViewBuilder
    private func cdlContent(for dataset: DatasetMeta) -> some View {
        let raw = dataset.cdlSummary()
        let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let displayed: String = {
            guard !query.isEmpty else { return raw }
            let matched = raw
                .split(separator: "\n", omittingEmptySubsequences: false)
                .filter { $0.lowercased().contains(query) }
                .map(String.init)
            return matched.isEmpty ? "// No lines matching \"\(searchText)\"" : matched.joined(separator: "\n")
        }()

        ScrollView([.vertical, .horizontal]) {
            Text(displayed)
                .font(.system(size: 12, design: .monospaced))
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(16)
        }
        .background(Color(nsColor: .textBackgroundColor))
    }

    private func matchesVariable(_ variable: VarMeta, query: String) -> Bool {
        guard !query.isEmpty else { return true }
        if variable.name.lowercased().contains(query) || variable.displayTitle.lowercased().contains(query) {
            return true
        }
        return variable.attrs.contains {
            $0.key.lowercased().contains(query) || $0.value.lowercased().contains(query)
        }
    }
}
