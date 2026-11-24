import AppKit
import SwiftUI

struct SettingsView: View {
    @Bindable var workspace: WorkspaceManager

    @State private var associations: [FileAssociationManager.AssociationStatus] = []
    @State private var registrationMessage: String?
    @State private var isRegistering = false
    @State private var isTestingBackend = false

    var body: some View {
        TabView {
            generalTab
                .tabItem {
                    Label("General", systemImage: "gearshape")
                }

            environmentTab
                .tabItem {
                    Label("Environment", systemImage: "terminal")
                }

            fileTypesTab
                .tabItem {
                    Label("File Types", systemImage: "doc.badge.gearshape")
                }
        }
        .padding(16)
        .frame(width: 580, height: 500)
        .onAppear {
            refreshAssociations()
        }
    }

    private var generalTab: some View {
        Form {
            Section("On Open Dataset") {
                Picker("Behavior", selection: Bindable(workspace.environment).datasetOpenBehavior) {
                    ForEach(DatasetOpenBehavior.allCases) { mode in
                        Text(mode.label).tag(mode)
                    }
                }
                .pickerStyle(.radioGroup)
            }

            Section("Subregion Selection") {
                Picker("Box-select default action", selection: Bindable(workspace.environment).boxSelectOpensNewTab) {
                    Text("Drill down in current tab (Path Bar)").tag(false)
                    Text("Open in a new native tab").tag(true)
                }
                .pickerStyle(.radioGroup)
                Text("Tip: Hold Option (⌥) while dragging a box to open in a new tab anytime.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("Preview Quality") {
                Toggle("Fast LOD preview for large grids (>3M points)", isOn: Bindable(workspace.environment).defaultPreviewLOD)
                Stepper("Default preview DPI: \(workspace.environment.defaultPreviewDPI)", value: Bindable(workspace.environment).defaultPreviewDPI, in: 72...300, step: 25)
            }

            Section("Map Borders") {
                Toggle("Enable GMT-China CN-border options", isOn: Bindable(workspace.environment).enableCNBorders)
                Text("Show CN-border L1/La choices in Inspector Borders and dataset controls in Environment.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }

    private var environmentTab: some View {
        Form {
            Section("Runtime Paths (Blank = Auto-Detect)") {
                pathRow(
                    title: "Python",
                    placeholder: workspace.environment.resolvedPythonPath ?? "Not found",
                    text: Bindable(workspace.environment).pythonPathOverride
                )
                pathRow(
                    title: "GMT 6",
                    placeholder: workspace.environment.resolvedGMTPath ?? "Auto via Python / PATH",
                    text: Bindable(workspace.environment).gmtPathOverride
                )
                pathRow(
                    title: "Source Root",
                    placeholder: workspace.environment.resolvedSourceRoot ?? "Not found",
                    text: Bindable(workspace.environment).sourceRootOverride,
                    chooseDirectory: true
                )
                if workspace.environment.enableCNBorders {
                    pathRow(
                        title: "CN-border",
                        placeholder: workspace.cnBorderStatus?.defaultDir ?? "~/.gmt/china-geospatial-data",
                        text: Bindable(workspace.environment).cnBorderDirOverride,
                        chooseDirectory: true
                    )
                }
            }

            if workspace.environment.enableCNBorders {
                Section("GMT-China CN-border Dataset") {
                    HStack {
                        if let status = workspace.cnBorderStatus, status.installed {
                            Label("Installed (\(status.laPath != nil ? "La + L1" : "L1"))", systemImage: "checkmark.circle.fill")
                                .foregroundStyle(.green)
                        } else {
                            Label("Not installed", systemImage: "exclamationmark.circle")
                                .foregroundStyle(.secondary)
                        }
                        Spacer()
                        Button {
                            Task { await workspace.downloadCNBorder() }
                        } label: {
                            if workspace.isDownloadingCNBorder {
                                ProgressView().controlSize(.small)
                            } else {
                                Text("Download / Update CN-border")
                            }
                        }
                        .disabled(workspace.isDownloadingCNBorder)

                        Button("Import ZIP…") {
                            Task { await workspace.importCNBorderZip() }
                        }
                        .disabled(workspace.isDownloadingCNBorder)
                    }
                    if let err = workspace.cnBorderError {
                        Text(err)
                            .font(.caption)
                            .foregroundStyle(.red)
                    }
                }
            }

            Section("Backend Status") {
                if let info = workspace.serverInfo {
                    LabeledContent("GMT Version", value: info.gmtVersion)
                    LabeledContent("GMT Binary", value: info.gmtBin)
                    LabeledContent("Python", value: info.python)
                } else if let err = workspace.backendError {
                    Text(err)
                        .font(.caption)
                        .foregroundStyle(.red)
                        .textSelection(.enabled)
                } else {
                    Text("Backend starts automatically when needed.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                HStack {
                    Button("Auto-Detect") {
                        workspace.environment.resetOverridesToAutoDetect()
                    }
                    Spacer()
                    Button {
                        Task {
                            isTestingBackend = true
                            await workspace.restartBackend()
                            isTestingBackend = false
                        }
                    } label: {
                        if isTestingBackend {
                            ProgressView().controlSize(.small)
                        } else {
                            Text("Restart & Test Backend")
                        }
                    }
                    .buttonStyle(.borderedProminent)
                }
            }
        }
        .formStyle(.grouped)
    }

    private var fileTypesTab: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Register Graticule as the default macOS application for NetCDF, HDF, and GMT grid files.")
                .font(.subheadline)
                .foregroundStyle(.secondary)

            Table(associations) {
                TableColumn("Extension") { item in
                    Text(".\(item.ext)")
                        .font(.system(.body, design: .monospaced))
                }
                .width(80)
                TableColumn("UTI") { item in
                    Text(item.utiIdentifier)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                TableColumn("Current Default App") { item in
                    HStack(spacing: 6) {
                        Image(systemName: item.isDefault ? "checkmark.circle.fill" : "circle")
                            .foregroundStyle(item.isDefault ? .green : .secondary)
                        Text(item.currentAppName)
                    }
                }
            }

            if let registrationMessage {
                Text(registrationMessage)
                    .font(.caption)
                    .foregroundStyle(registrationMessage.hasPrefix("Error") ? .red : .green)
            }

            HStack {
                Button("Refresh") {
                    refreshAssociations()
                }
                Spacer()
                Button {
                    Task {
                        isRegistering = true
                        registrationMessage = nil
                        defer { isRegistering = false }
                        do {
                            let res = try await FileAssociationManager.registerAsDefaultForAll()
                            registrationMessage = "Registered \(res.count) extensions as default."
                            refreshAssociations()
                        } catch {
                            registrationMessage = "Error: \(error.localizedDescription)"
                        }
                    }
                } label: {
                    if isRegistering {
                        ProgressView().controlSize(.small)
                    } else {
                        Text("Set Graticule as Default for All")
                    }
                }
                .buttonStyle(.borderedProminent)
            }
        }
    }

    @ViewBuilder
    private func pathRow(title: String, placeholder: String, text: Binding<String>, chooseDirectory: Bool = false) -> some View {
        HStack {
            Text(title)
                .frame(width: 85, alignment: .leading)
            TextField("", text: text, prompt: Text(placeholder))
                .labelsHidden()
                .textFieldStyle(.roundedBorder)
                .font(.caption.monospaced())
            Button("Browse…") {
                let panel = NSOpenPanel()
                panel.canChooseFiles = !chooseDirectory
                panel.canChooseDirectories = chooseDirectory
                panel.allowsMultipleSelection = false
                if panel.runModal() == .OK, let url = panel.url {
                    text.wrappedValue = url.path
                }
            }
        }
    }

    private func refreshAssociations() {
        associations = FileAssociationManager.currentAssociations()
    }
}
