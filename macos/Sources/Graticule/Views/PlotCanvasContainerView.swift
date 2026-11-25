import SwiftUI

private struct AdaptiveGlassBackground: ViewModifier {
    let cornerRadius: CGFloat

    func body(content: Content) -> some View {
        let shape = RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
        if #available(macOS 26.0, *) {
            content
                .glassEffect(.regular, in: shape)
                .shadow(color: .black.opacity(0.08), radius: 8, y: 2)
        } else {
            content
                .background(.ultraThinMaterial, in: shape)
                .overlay(
                    shape
                        .stroke(Color.primary.opacity(0.10), lineWidth: 1)
                )
                .shadow(color: .black.opacity(0.10), radius: 10, y: 3)
        }
    }
}

struct PlotCanvasContainerView: View {
    @ObservedObject var workspace: WorkspaceManager
    @ObservedObject var session: PlotSession

    var body: some View {
        ZStack {
            Group {
                if let render = session.currentRender {
                    MapCanvasView(
                        imagePath: render.imagePath,
                        mapBbox: render.mapBbox,
                        hoverGrid: session.hoverGrid,
                        interactionMode: session.interactionMode,
                        fitRequestToken: session.fitRequestToken,
                        actualSizeRequestToken: session.actualSizeRequestToken,
                        onHoverCoordinate: { coord in
                            session.cursorCoord = coord
                        },
                        onZoomChanged: { scale in
                            session.zoomScale = scale
                        },
                        onBoxSelected: { u0, v0, u1, v1, forceNewTab in
                            Task {
                                await workspace.handleBoxSelection(
                                    inSession: session.id,
                                    u0: u0,
                                    v0: v0,
                                    u1: u1,
                                    v1: v1,
                                    forceNewTab: forceNewTab
                                )
                            }
                        }
                    )
                } else if session.isRendering {
                    VStack(spacing: 10) {
                        ProgressView()
                            .controlSize(.regular)
                        Text("Rendering map with GMT…")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else if workspace.datasets.isEmpty {
                    emptyStateView
                } else {
                    noActivePlotView
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)

            VStack(spacing: 8) {
                if session.regionHistory.isDrilledDown {
                    RegionBreadcrumbBar(workspace: workspace, session: session)
                }

                if let error = session.errorMessage {
                    errorBanner(error)
                }

                Spacer(minLength: 0)

                if session.config != nil {
                    floatingBottomHUD
                }
            }
            .padding(.top, 10)
            .padding(.bottom, 12)
            .padding(.horizontal, 14)
            .zIndex(10)
        }
    }

    @ViewBuilder
    private var noActivePlotView: some View {
        let inspectedPath = session.inspectedTarget?.datasetPath ?? workspace.datasets.first?.filePath
        AdaptiveEmptyState(
            "Select a Variable to Plot",
            systemImage: "map",
            description: "Double-click a plottable grid in the sidebar to render. Single-click any file or variable to inspect metadata."
        ) {
            if let path = inspectedPath {
                Button("View CDL…") {
                    workspace.openStructureSheet(datasetPath: path, inSession: session.id)
                }
                .buttonStyle(.bordered)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var emptyStateView: some View {
        AdaptiveEmptyState(
            "Open a NetCDF or GMT Grid",
            systemImage: "globe.asia.australia",
            description: "Drop .nc, .nc4, .cdf, .grd, .h5, or .npz files here, or open from Finder."
        ) {
            VStack(spacing: 12) {
                Button("Open Dataset…") {
                    workspace.openFileDialog(in: session.id)
                }
                .buttonStyle(.borderedProminent)
                .keyboardShortcut("o", modifiers: .command)

                environmentStatusCard
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    @ViewBuilder
    private var environmentStatusCard: some View {
        let pyPath = workspace.environment.resolvedPythonPath
        let gmtPath = workspace.environment.resolvedGMTPath
        let gsPath = workspace.serverInfo?.gsBin ?? workspace.environment.resolvedGhostscriptPath
        let allReady = (pyPath != nil && gmtPath != nil && gsPath != nil && workspace.backendError == nil)

        Group {
            if let info = workspace.serverInfo, allReady {
                HStack(spacing: 6) {
                    Image(systemName: "checkmark.circle.fill")
                        .foregroundStyle(.green)
                    Text("GMT \(info.gmtVersion) · Python · Ghostscript Ready")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            } else {
                VStack(alignment: .leading, spacing: 6) {
                    Label("First-Run Environment Setup", systemImage: "wrench.and.screwdriver")
                        .font(.caption.weight(.semibold))
                    statusRow(label: "Python 3.9+ (numpy, xarray, netCDF4)", ok: pyPath != nil)
                    statusRow(label: "GMT 6", ok: gmtPath != nil)
                    statusRow(label: "Ghostscript (gs)", ok: gsPath != nil)
                    if let err = workspace.backendError, !err.isEmpty {
                        Text(err)
                            .font(.caption2)
                            .foregroundStyle(.red)
                            .lineLimit(2)
                            .textSelection(.enabled)
                    }
                    Text("Install GMT 6, Ghostscript, and Python dependencies (via micromamba/conda, Homebrew, or MacPorts), or set custom binary paths in Settings (⌘,).")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    HStack(spacing: 8) {
                        if #available(macOS 14.0, *) {
                            SettingsLink {
                                Text("Environment Settings…")
                            }
                            .controlSize(.small)
                        } else {
                            Button("Environment Settings…") {
                                NSApp.sendAction(Selector(("showSettingsWindow:")), to: nil, from: nil)
                            }
                            .controlSize(.small)
                        }
                        Button("Retry") {
                            Task { await workspace.restartBackend() }
                        }
                        .controlSize(.small)
                    }
                    .padding(.top, 2)
                }
                .padding(12)
                .frame(maxWidth: 420, alignment: .leading)
                .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .stroke(Color.primary.opacity(0.08), lineWidth: 1)
                )
            }
        }
        .padding(.top, 6)
    }

    @ViewBuilder
    private func statusRow(label: String, ok: Bool) -> some View {
        HStack(spacing: 6) {
            Image(systemName: ok ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                .foregroundStyle(ok ? .green : .orange)
                .font(.caption)
            Text(label)
                .font(.caption)
            Spacer(minLength: 6)
            Text(ok ? "OK" : "Missing")
                .font(.caption2.weight(.medium))
                .foregroundStyle(ok ? AnyShapeStyle(.secondary) : AnyShapeStyle(Color.orange))
        }
    }

    @ViewBuilder
    private func errorBanner(_ message: String) -> some View {
        HStack(spacing: 8) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(.orange)
            Text(message)
                .font(.caption)
                .lineLimit(3)
                .textSelection(.enabled)
            Spacer(minLength: 8)
            Button {
                session.errorMessage = nil
            } label: {
                Image(systemName: "xmark")
                    .font(.caption2.weight(.semibold))
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 10))
        .overlay(
            RoundedRectangle(cornerRadius: 10)
                .stroke(Color.orange.opacity(0.45), lineWidth: 1)
        )
        .shadow(color: .black.opacity(0.08), radius: 6, y: 2)
    }

    @ViewBuilder
    private var floatingBottomHUD: some View {
        let dataset = workspace.dataset(for: session.datasetPath)
        let variable = workspace.variable(named: session.variableName, inDataset: session.datasetPath)
        let sliceDims = variable?.sliceDims ?? []
        let isGeo = session.config?.isGeographic ?? true

        VStack(alignment: .leading, spacing: 8) {
            if !sliceDims.isEmpty, let dataset {
                ForEach(sliceDims, id: \.self) { dim in
                    sliceRow(dim: dim, dataset: dataset)
                }
                Divider()
            }

            HStack(spacing: 12) {
                if let coord = session.cursorCoord {
                    let coordText = isGeo
                        ? String(format: "Lon %.3f°  Lat %.3f°", coord.lon, coord.lat)
                        : String(format: "X %.4g  Y %.4g", coord.lon, coord.lat)
                    Text(coordText)
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.primary)
                } else {
                    Text(isGeo ? "Lon --  Lat --" : "X --  Y --")
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.secondary)
                }

                Divider()
                    .frame(height: 12)

                Text(String(format: "%.0f%%", session.zoomScale * 100.0))
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)

                if let region = session.config?.region, region.count == 4 {
                    Divider()
                        .frame(height: 12)
                    Text(RegionEntry.formatRegionLabel(region, isGeographic: isGeo))
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }

                Spacer(minLength: 8)

                if session.isRendering || session.isScanningRange {
                    ProgressView()
                        .controlSize(.small)
                }

                Text(session.statusText)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 9)
        .frame(maxWidth: 760)
        .modifier(AdaptiveGlassBackground(cornerRadius: 12))
    }

    @ViewBuilder
    private func sliceRow(dim: String, dataset: DatasetMeta) -> some View {
        let size = max(1, dataset.dimensions[dim] ?? 1)
        let maxIdx = max(0, size - 1)
        let currentIndex = session.config?.sliceIndices[dim] ?? 0
        let coordLabels = dataset.dimensionCoords[dim] ?? []
        let displayLabel = coordLabels.indices.contains(currentIndex) ? coordLabels[currentIndex] : "\(currentIndex)"

        HStack(spacing: 8) {
            Text(dim)
                .font(.caption.weight(.medium))
                .foregroundStyle(.secondary)
                .frame(minWidth: 46, alignment: .leading)

            Button {
                updateSlice(dim: dim, newIndex: max(0, currentIndex - 1), renderNow: true)
            } label: {
                Image(systemName: "chevron.left")
                    .font(.caption2.weight(.semibold))
            }
            .buttonStyle(.borderless)
            .disabled(currentIndex <= 0)

            Slider(
                value: Binding(
                    get: { Double(currentIndex) },
                    set: { newVal in
                        let idx = Int(newVal.rounded())
                        session.config?.sliceIndices[dim] = idx
                    }
                ),
                in: 0...Double(max(1, maxIdx)),
                step: 1,
                onEditingChanged: { editing in
                    if !editing {
                        session.scheduleRender(delayMs: 40)
                    }
                }
            )
            .disabled(maxIdx == 0)

            Button {
                updateSlice(dim: dim, newIndex: min(maxIdx, currentIndex + 1), renderNow: true)
            } label: {
                Image(systemName: "chevron.right")
                    .font(.caption2.weight(.semibold))
            }
            .buttonStyle(.borderless)
            .disabled(currentIndex >= maxIdx)

            Text("\(displayLabel) (\(currentIndex)/\(maxIdx))")
                .font(.caption.monospacedDigit())
                .foregroundStyle(.primary)
                .frame(minWidth: 110, alignment: .trailing)
        }
    }

    private func updateSlice(dim: String, newIndex: Int, renderNow: Bool) {
        session.config?.sliceIndices[dim] = newIndex
        if renderNow {
            session.scheduleRender(delayMs: 40)
        }
    }
}

struct RegionBreadcrumbBar: View {
    @ObservedObject var workspace: WorkspaceManager
    @ObservedObject var session: PlotSession

    var body: some View {
        HStack(spacing: 8) {
            HStack(spacing: 2) {
                Button {
                    Task { await session.navigateBack() }
                } label: {
                    Image(systemName: "chevron.left")
                }
                .disabled(!session.regionHistory.canGoBack)
                .help("Back (⌘[)")

                Button {
                    Task { await session.navigateForward() }
                } label: {
                    Image(systemName: "chevron.right")
                }
                .disabled(!session.regionHistory.canGoForward)
                .help("Forward (⌘])")
            }
            .buttonStyle(.borderless)

            Divider()
                .frame(height: 14)

            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 4) {
                    let entries = session.regionHistory.entries
                    ForEach(Array(entries.enumerated()), id: \.element.id) { index, entry in
                        if index > 0 {
                            Image(systemName: "chevron.right")
                                .font(.caption2)
                                .foregroundStyle(.tertiary)
                        }
                        let isCurrent = index == session.regionHistory.currentIndex
                        Button {
                            Task { await session.jumpToHistory(index: index) }
                        } label: {
                            Text(entry.label)
                                .font(.caption)
                                .fontWeight(isCurrent ? .semibold : .regular)
                                .foregroundStyle(isCurrent ? Color.accentColor : .primary)
                                .padding(.horizontal, 6)
                                .padding(.vertical, 2)
                                .background(
                                    RoundedRectangle(cornerRadius: 5)
                                        .fill(isCurrent ? Color.accentColor.opacity(0.12) : Color.clear)
                                )
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
            .fixedSize(horizontal: false, vertical: true)

            Spacer(minLength: 8)

            if let region = session.config?.region {
                Button {
                    Task {
                        await workspace.applySubregion(
                            inSession: session.id,
                            region: region,
                            label: session.regionHistory.current?.label,
                            explicitProjection: session.config?.projectionMode == "manual" ? session.config?.projection : nil,
                            openInNewTab: true
                        )
                    }
                } label: {
                    Image(systemName: "arrow.up.forward.app")
                        .font(.caption)
                }
                .buttonStyle(.borderless)
                .help("Open current region in a new native tab")
            }

            Button {
                Task { await session.resetRegionToFullExtent() }
            } label: {
                Label("Full Grid", systemImage: "arrow.counterclockwise")
                    .font(.caption)
            }
            .buttonStyle(.borderless)
            .help("Reset to Full Dataset Extent (⇧⌘0)")
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 7)
        .modifier(AdaptiveGlassBackground(cornerRadius: 10))
    }
}
