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
                if session.datasetPath == nil {
                    emptyStateView
                } else if let render = session.currentRender {
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
                } else {
                    datasetOverviewCard
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
    private var datasetOverviewCard: some View {
        if let dataset = workspace.dataset(for: session.datasetPath) {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    HStack(alignment: .top, spacing: 12) {
                        Image(systemName: "doc.text.magnifyingglass")
                            .font(.system(size: 28))
                            .foregroundStyle(Color.accentColor)
                        VStack(alignment: .leading, spacing: 3) {
                            Text(dataset.fileName)
                                .font(.title3.weight(.semibold))
                            Text(dataset.filePath)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .lineLimit(2)
                                .textSelection(.enabled)
                        }
                        Spacer()
                        if let firstVar = dataset.plotableVariables.first {
                            Button("Plot \(firstVar.name)") {
                                Task {
                                    await workspace.selectVariable(
                                        datasetPath: dataset.filePath,
                                        varName: firstVar.name,
                                        inSession: session.id,
                                        openInNewTab: false
                                    )
                                }
                            }
                            .buttonStyle(.borderedProminent)
                        }
                    }

                    if !dataset.dimensions.isEmpty {
                        HStack(spacing: 8) {
                            ForEach(dataset.dimensions.keys.sorted(), id: \.self) { dim in
                                Text("\(dim): \(dataset.dimensions[dim] ?? 0)")
                                    .font(.caption.monospacedDigit())
                                    .padding(.horizontal, 8)
                                    .padding(.vertical, 3)
                                    .background(.quaternary.opacity(0.6), in: Capsule())
                            }
                        }
                    }

                    Divider()

                    if dataset.plotableVariables.isEmpty {
                        AdaptiveEmptyState(
                            "No Regular 2D Grid Variables",
                            systemImage: "info.circle",
                            description: "Inspect variable attributes in the right Info panel."
                        )
                    } else {
                        Text("Plottable Grid Variables (\(dataset.plotableVariables.count))")
                            .font(.headline)

                        VStack(spacing: 6) {
                            ForEach(dataset.plotableVariables.prefix(12)) { variable in
                                HStack(spacing: 10) {
                                    Image(systemName: variable.sliceDims.isEmpty ? "map" : "square.stack.3d.up")
                                        .foregroundStyle(.secondary)
                                        .frame(width: 16)
                                    VStack(alignment: .leading, spacing: 1) {
                                        Text(variable.name)
                                            .font(.body.weight(.medium))
                                        Text("\(variable.displayTitle) · [\(variable.shapeSummary)]")
                                            .font(.caption)
                                            .foregroundStyle(.secondary)
                                            .lineLimit(1)
                                    }
                                    Spacer()
                                    Button("Info") {
                                        workspace.inspectVariable(
                                            datasetPath: dataset.filePath,
                                            varName: variable.name,
                                            inSession: session.id
                                        )
                                    }
                                    .buttonStyle(.bordered)
                                    .controlSize(.small)

                                    Button("Plot") {
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
                                .padding(.horizontal, 10)
                                .padding(.vertical, 7)
                                .background(.quaternary.opacity(0.35), in: RoundedRectangle(cornerRadius: 8))
                            }
                            if dataset.plotableVariables.count > 12 {
                                Text("Select any remaining variable in the left sidebar.")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                        }
                    }
                }
                .padding(24)
                .frame(maxWidth: 660)
                .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: 14, style: .continuous)
                        .stroke(Color.primary.opacity(0.08), lineWidth: 1)
                )
                .padding(28)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            AdaptiveEmptyState(
                "Select a Plottable Grid",
                systemImage: "map",
                description: "Choose a 2D+ variable from the sidebar to render."
            )
        }
    }

    private var emptyStateView: some View {
        AdaptiveEmptyState(
            "Open a NetCDF or GMT Grid",
            systemImage: "globe.asia.australia",
            description: "Drop .nc, .nc4, .cdf, .grd, or .h5 files here, or open from Finder."
        ) {
            Button("Open Dataset…") {
                workspace.openFileDialog(in: session.id)
            }
            .buttonStyle(.borderedProminent)
            .keyboardShortcut("o", modifiers: .command)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
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

        VStack(alignment: .leading, spacing: 8) {
            if !sliceDims.isEmpty, let dataset {
                ForEach(sliceDims, id: \.self) { dim in
                    sliceRow(dim: dim, dataset: dataset)
                }
                Divider()
            }

            HStack(spacing: 12) {
                if let coord = session.cursorCoord {
                    Text(String(format: "Lon %.3f°  Lat %.3f°", coord.lon, coord.lat))
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.primary)
                } else {
                    Text("Lon --  Lat --")
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
                    Text(RegionEntry.formatRegionLabel(region))
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
