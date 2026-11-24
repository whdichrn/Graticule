import AppKit
import SwiftUI

struct ScriptEditorSheet: View {
    @Environment(\.dismiss) private var dismiss

    @Bindable var workspace: WorkspaceManager
    @Bindable var session: PlotSession

    @State private var scriptText: String = ""
    @State private var isLoading = true
    @State private var isRunning = false
    @State private var errorMessage: String?

    var body: some View {
        VStack(spacing: 12) {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text("GMT Modern Mode Script")
                        .font(.headline)
                    Text("Edit parameters and sync back to controls, or execute bash directly.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Button("Copy") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(scriptText, forType: .string)
                }
                Button("Export .sh…") {
                    workspace.exportScript(for: session.id)
                }
            }

            if isLoading {
                ProgressView("Generating GMT script…")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                TextEditor(text: $scriptText)
                    .font(.system(.body, design: .monospaced))
                    .padding(4)
                    .background(Color(nsColor: .textBackgroundColor))
                    .clipShape(RoundedRectangle(cornerRadius: 8))
                    .overlay(
                        RoundedRectangle(cornerRadius: 8)
                            .stroke(Color.primary.opacity(0.12), lineWidth: 1)
                    )
            }

            if let errorMessage {
                Text(errorMessage)
                    .font(.caption)
                    .foregroundStyle(.red)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .textSelection(.enabled)
            }

            HStack {
                Button("Close") {
                    dismiss()
                }
                .keyboardShortcut(.cancelAction)

                Spacer()

                Button("Run Directly") {
                    Task { await runDirectly() }
                }
                .disabled(isLoading || isRunning)

                Button("Apply to GUI & Render") {
                    Task { await applyAndRender() }
                }
                .buttonStyle(.borderedProminent)
                .disabled(isLoading || isRunning)
            }
        }
        .padding(18)
        .frame(minWidth: 720, minHeight: 500)
        .task {
            await loadScript()
        }
    }

    private func loadScript() async {
        guard let cfg = session.config else {
            errorMessage = "No active plot configuration."
            isLoading = false
            return
        }
        do {
            scriptText = try await workspace.rpc.generateScript(config: cfg, outputFilename: "output.png")
            isLoading = false
        } catch {
            errorMessage = error.localizedDescription
            isLoading = false
        }
    }

    private func applyAndRender() async {
        guard let fallback = session.config else { return }
        isRunning = true
        errorMessage = nil
        defer { isRunning = false }
        do {
            let parsed = try await workspace.rpc.parseScript(scriptText, fallback: fallback)
            session.config = parsed
            await session.refreshRecommendations()
            await session.renderNow()
            dismiss()
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func runDirectly() async {
        guard let fallback = session.config else { return }
        isRunning = true
        errorMessage = nil
        defer { isRunning = false }
        do {
            let result = try await workspace.rpc.runScript(scriptText, fallback: fallback)
            if let parsed = result.parsedConfig {
                session.config = parsed
            }
            if let imagePath = result.imagePath {
                let effective = result.parsedConfig ?? fallback
                let render = RenderResult(
                    imagePath: imagePath,
                    resolvedConfig: effective,
                    mapBbox: nil,
                    dimsCm: nil,
                    hoverGridSize: 0,
                    hoverB64: nil,
                    elapsedSec: 0
                )
                session.applyRenderResult(render, styleSignature: effective.styleSignature, customMessage: "Executed custom GMT script")
                dismiss()
            } else {
                errorMessage = "Script completed without a raster PNG/JPG/TIFF preview in its working directory."
            }
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}
