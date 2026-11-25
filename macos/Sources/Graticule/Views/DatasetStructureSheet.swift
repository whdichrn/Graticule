import AppKit
import SwiftUI

struct DatasetStructureSheet: View {
    @ObservedObject var workspace: WorkspaceManager
    @ObservedObject var session: PlotSession
    let datasetPath: String

    @Environment(\.dismiss) private var dismiss
    @State private var searchText = ""
    @State private var wrapLines = true
    @State private var didCopy = false

    private var dataset: DatasetMeta? {
        workspace.dataset(for: datasetPath)
    }

    var body: some View {
        VStack(spacing: 0) {
            if let dataset {
                headerView(for: dataset)
                Divider()
                cdlContent(for: dataset)
            } else {
                AdaptiveEmptyState(
                    "Dataset Closed",
                    systemImage: "doc.questionmark",
                    description: "The inspected file is no longer loaded."
                )
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .frame(minWidth: 680, idealWidth: 760, minHeight: 500, idealHeight: 600)
    }

    @ViewBuilder
    private func headerView(for dataset: DatasetMeta) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .top, spacing: 12) {
                VStack(alignment: .leading, spacing: 3) {
                    Text("\(dataset.fileName) — CDL (ncdump -h)")
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

            HStack(spacing: 12) {
                HStack(spacing: 6) {
                    Image(systemName: "magnifyingglass")
                        .foregroundStyle(.secondary)
                        .font(.caption)
                    TextField("Filter CDL lines…", text: $searchText)
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

                Toggle("Wrap lines", isOn: $wrapLines)
                    .toggleStyle(.checkbox)
                    .font(.subheadline)
            }
        }
        .padding(16)
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

        if wrapLines {
            ScrollView(.vertical) {
                Text(displayed)
                    .font(.system(size: 12, design: .monospaced))
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(16)
            }
            .background(Color(nsColor: .textBackgroundColor))
        } else {
            ScrollView([.vertical, .horizontal]) {
                Text(displayed)
                    .font(.system(size: 12, design: .monospaced))
                    .textSelection(.enabled)
                    .fixedSize(horizontal: true, vertical: false)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(16)
            }
            .background(Color(nsColor: .textBackgroundColor))
        }
    }
}
