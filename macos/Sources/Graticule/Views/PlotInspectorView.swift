import SwiftUI

struct PlotInspectorView: View {
    @ObservedObject var workspace: WorkspaceManager
    @ObservedObject var session: PlotSession

    @State private var advancedExpanded = false
    @State private var customProjectionText = ""
    @State private var customCptText = ""

    var body: some View {
        VStack(spacing: 0) {
            Picker("Inspector", selection: $session.selectedInspectorTab) {
                ForEach(InspectorTab.allCases) { tab in
                    Text(tab.rawValue).tag(tab)
                }
            }
            .pickerStyle(.segmented)
            .padding(.horizontal, 12)
            .padding(.vertical, 8)

            Divider()

            if session.config != nil || session.selectedInspectorTab == .info {
                switch session.selectedInspectorTab {
                case .map:
                    mapInspectorForm
                case .style:
                    styleInspectorForm
                case .info:
                    infoInspectorForm
                }
            } else {
                AdaptiveEmptyState(
                    "No Active Plot",
                    systemImage: "slider.horizontal.3",
                    description: "Select a variable to configure map and color options."
                )
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .onChange(of: session.config?.projection) { newValue in
            customProjectionText = newValue ?? ""
        }
        .onChange(of: session.config?.cpt) { newValue in
            customCptText = newValue ?? ""
        }
        .onAppear {
            customProjectionText = session.config?.projection ?? ""
            customCptText = session.config?.cpt ?? ""
        }
    }

    private func binding<Value>(
        _ keyPath: WritableKeyPath<PlotConfig, Value>,
        autoRender: Bool = true,
        afterSet: (() -> Void)? = nil
    ) -> Binding<Value> {
        Binding(
            get: {
                session.config?[keyPath: keyPath] ?? PlotConfig()[keyPath: keyPath]
            },
            set: { newValue in
                guard session.config != nil else { return }
                session.config?[keyPath: keyPath] = newValue
                afterSet?()
                if autoRender {
                    session.scheduleRender(delayMs: 360)
                }
            }
        )
    }

    private func regionBoundBinding(index: Int) -> Binding<Double> {
        Binding(
            get: {
                guard let region = session.config?.region, region.indices.contains(index) else {
                    return [0, 360, -90, 90][index]
                }
                return region[index]
            },
            set: { newValue in
                guard var region = session.config?.region ?? [0, 360, -90, 90] as [Double]?,
                      region.indices.contains(index) else { return }
                region[index] = newValue
                session.config?.region = region
            }
        )
    }

    private func commitRegionBounds() {
        Task {
            if let region = session.config?.region,
               region.count == 4,
               region[1] > region[0],
               region[3] > region[2],
               region != session.regionHistory.current?.region {
                await workspace.applySubregion(
                    inSession: session.id,
                    region: region,
                    explicitProjection: session.config?.projectionMode == "manual" ? session.config?.projection : nil,
                    openInNewTab: false
                )
            } else {
                await session.refreshRecommendations()
                await session.renderNow()
            }
        }
    }

    @ViewBuilder
    private var mapInspectorForm: some View {
        Form {
            Section("Projection") {
                Toggle("Auto-recommend for region", isOn: Binding(
                    get: { session.config?.projectionMode == "auto" },
                    set: { isAuto in
                        session.config?.projectionMode = isAuto ? "auto" : "manual"
                        Task {
                            await session.refreshRecommendations()
                            await session.renderNow()
                        }
                    }
                ))

                let options = session.recommendedProjections
                Picker("Preset", selection: Binding(
                    get: { session.config?.projection ?? "" },
                    set: { newCode in
                        session.config?.projection = newCode
                        session.config?.projectionMode = "manual"
                        customProjectionText = newCode
                        session.scheduleRender(delayMs: 250)
                    }
                )) {
                    ForEach(options) { opt in
                        Text(opt.label).tag(opt.code)
                    }
                    if let current = session.config?.projection,
                       !current.isEmpty,
                       !options.contains(where: { $0.code == current }) {
                        Text("Custom (\(current))").tag(current)
                    }
                }

                HStack {
                    Text("GMT -J")
                        .foregroundStyle(.secondary)
                    TextField("", text: $customProjectionText, prompt: Text("e.g. M16c"))
                        .labelsHidden()
                        .textFieldStyle(.roundedBorder)
                        .font(.system(.body, design: .monospaced))
                        .onSubmit {
                            let code = customProjectionText.trimmingCharacters(in: .whitespacesAndNewlines)
                                .replacingOccurrences(of: "^-J", with: "", options: .regularExpression)
                            guard !code.isEmpty else { return }
                            session.config?.projection = code
                            session.config?.projectionMode = "manual"
                            session.scheduleRender(delayMs: 100)
                        }
                }
            }

            Section("Region (-R)") {
                Grid(horizontalSpacing: 10, verticalSpacing: 8) {
                    GridRow {
                        boundField("W", index: 0)
                        boundField("E", index: 1)
                    }
                    GridRow {
                        boundField("S", index: 2)
                        boundField("N", index: 3)
                    }
                }
                .padding(.vertical, 2)

                HStack {
                    Button("Apply Bounds") {
                        commitRegionBounds()
                    }
                    Spacer()
                    Button("Full Extent") {
                        Task { await session.resetRegionToFullExtent() }
                    }
                }
            }

            Section("Overlays & Masking") {
                Picker("Mask area", selection: binding(\.maskMode)) {
                    Text("None").tag("none")
                    Text("Hide land (ocean only)").tag("land")
                    Text("Hide ocean (land only)").tag("ocean")
                }
                if session.config?.maskMode != "none" {
                    TextField("Mask fill", text: binding(\.maskColor))
                }
                Toggle("Coastlines", isOn: binding(\.showCoast))

                let cnEnabled = workspace.environment.enableCNBorders
                Picker("Borders", selection: Binding(
                    get: {
                        let raw = session.config?.borderMode ?? "none"
                        if cnEnabled { return raw }
                        if raw == "gmt_global" || raw.hasPrefix("global_cn_") {
                            return "gmt_global"
                        }
                        return "none"
                    },
                    set: { newMode in
                        guard session.config != nil else { return }
                        session.config?.borderMode = newMode
                        session.config?.showBorders = (newMode == "gmt_global" || newMode == "global_cn_l1" || newMode == "global_cn_la")
                        session.config?.cnBorderDir = workspace.environment.cnBorderDirOverride
                        session.scheduleRender(delayMs: 250)
                    }
                )) {
                    Text("None").tag("none")
                    Text("GMT Built-in (-N1)").tag("gmt_global")
                    if cnEnabled {
                        Divider()
                        Text("CN-border L1 (National + 10-dash)").tag("cn_l1")
                        Text("CN-border La (+ Provinces)").tag("cn_la")
                        Text("Global + CN-border L1").tag("global_cn_l1")
                        Text("Global + CN-border La").tag("global_cn_la")
                    }
                }

                let activeBorder = session.config?.borderMode ?? "none"
                if cnEnabled && activeBorder.contains("cn_") {
                    TextField("Border pen", text: binding(\.borderPen))
                    if workspace.cnBorderStatus?.installed != true {
                        VStack(alignment: .leading, spacing: 6) {
                            Text("GMT-China CN-border dataset not found locally.")
                                .font(.caption)
                                .foregroundStyle(.orange)
                            HStack(spacing: 8) {
                                Button {
                                    Task { await workspace.downloadCNBorder(reRenderSessionID: session.id) }
                                } label: {
                                    if workspace.isDownloadingCNBorder {
                                        HStack(spacing: 6) {
                                            ProgressView().controlSize(.small)
                                            Text("Downloading…")
                                        }
                                    } else {
                                        Label("Download CN-border", systemImage: "arrow.down.circle")
                                    }
                                }
                                .disabled(workspace.isDownloadingCNBorder)

                                Button("Import ZIP…") {
                                    Task { await workspace.importCNBorderZip(reRenderSessionID: session.id) }
                                }
                                .disabled(workspace.isDownloadingCNBorder)
                            }
                        }
                        .padding(.vertical, 2)
                    }
                }

                Toggle("Frame & tick labels", isOn: binding(\.showFrame))
                Toggle("Gridlines", isOn: binding(\.showGrid))
                Toggle("Colorbar", isOn: binding(\.showColorbar))

                Picker("Coast detail", selection: binding(\.coastResolution)) {
                    Text("Crude").tag("c")
                    Text("Low").tag("l")
                    Text("Intermediate").tag("i")
                    Text("High").tag("h")
                    Text("Full").tag("f")
                    Text("Auto").tag("a")
                }
            }
        }
        .formStyle(.grouped)
    }

    @ViewBuilder
    private func boundField(_ label: String, index: Int) -> some View {
        HStack(spacing: 5) {
            Text(label)
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
                .frame(width: 14, alignment: .leading)
            TextField(
                "",
                value: regionBoundBinding(index: index),
                format: .number.precision(.fractionLength(0...4)),
                prompt: Text(label)
            )
            .labelsHidden()
            .textFieldStyle(.roundedBorder)
            .font(.caption.monospacedDigit())
            .frame(maxWidth: .infinity)
            .onSubmit {
                commitRegionBounds()
            }
        }
    }

    @ViewBuilder
    private var styleInspectorForm: some View {
        Form {
            Section("Palette (-C)") {
                let builtIn = GMTColorPalettes.builtInNames
                let currentCpt = session.config?.cpt ?? "turbo"

                Picker("Palette", selection: Binding(
                    get: { builtIn.contains(currentCpt) ? currentCpt : "__custom__" },
                    set: { picked in
                        guard picked != "__custom__" else { return }
                        session.config?.cpt = picked
                        customCptText = picked
                        session.scheduleRender(delayMs: 250)
                    }
                )) {
                    ForEach(builtIn, id: \.self) { name in
                        Text(name).tag(name)
                    }
                    if !builtIn.contains(currentCpt) {
                        Text("Custom").tag("__custom__")
                    }
                }

                GMTColorPalettes.gradient(for: currentCpt)
                    .frame(height: 12)
                    .clipShape(RoundedRectangle(cornerRadius: 4))
                    .overlay(
                        RoundedRectangle(cornerRadius: 4)
                            .stroke(Color.primary.opacity(0.12), lineWidth: 0.5)
                    )

                HStack {
                    Text("Custom / .cpt")
                        .foregroundStyle(.secondary)
                    TextField("", text: $customCptText, prompt: Text("palette, colors, or .cpt"))
                        .labelsHidden()
                        .textFieldStyle(.roundedBorder)
                        .onSubmit {
                            let trimmed = customCptText.trimmingCharacters(in: .whitespacesAndNewlines)
                            guard !trimmed.isEmpty else { return }
                            session.config?.cpt = trimmed
                            session.scheduleRender(delayMs: 120)
                        }
                }

                Picker("Interpolation", selection: binding(\.cptContinuous)) {
                    Text("Continuous (-Z)").tag(true)
                    Text("Discrete").tag(false)
                }
                .pickerStyle(.segmented)

                if session.config?.cptContinuous == false {
                    Stepper(
                        "Levels: \(session.config?.cptLevels ?? 16)",
                        value: binding(\.cptLevels),
                        in: 2...256
                    )
                }

                Toggle("Reverse palette (-Ic)", isOn: binding(\.cptReverse))
            }

            Section("Color Range (-T)") {
                Toggle("Auto-fit region & slice", isOn: Binding(
                    get: { session.config?.cptRange == nil },
                    set: { isAuto in
                        if isAuto {
                            session.config?.cptRange = nil
                        } else {
                            let resolved = session.currentRender?.resolvedConfig.cptRange ?? [-1.0, 1.0]
                            session.config?.cptRange = resolved
                        }
                        session.scheduleRender(delayMs: 200)
                    }
                ))

                Toggle("Symmetric around zero (±A)", isOn: binding(\.symmetricCpt))

                let displayRange = session.config?.cptRange ?? session.currentRender?.resolvedConfig.cptRange ?? [-1.0, 1.0]
                HStack {
                    Text("Min")
                        .foregroundStyle(.secondary)
                    TextField(
                        "",
                        value: Binding(
                            get: { displayRange[0] },
                            set: { newMin in
                                let hi = max(newMin + 1e-6, (session.config?.cptRange ?? displayRange)[1])
                                session.config?.cptRange = [newMin, hi]
                            }
                        ),
                        format: .number.precision(.fractionLength(0...6)),
                        prompt: Text("Min")
                    )
                    .labelsHidden()
                    .textFieldStyle(.roundedBorder)
                    .font(.caption.monospacedDigit())
                    .onSubmit { session.scheduleRender(delayMs: 100) }

                    Text("Max")
                        .foregroundStyle(.secondary)
                    TextField(
                        "",
                        value: Binding(
                            get: { displayRange[1] },
                            set: { newMax in
                                let lo = min(newMax - 1e-6, (session.config?.cptRange ?? displayRange)[0])
                                session.config?.cptRange = [lo, newMax]
                            }
                        ),
                        format: .number.precision(.fractionLength(0...6)),
                        prompt: Text("Max")
                    )
                    .labelsHidden()
                    .textFieldStyle(.roundedBorder)
                    .font(.caption.monospacedDigit())
                    .onSubmit { session.scheduleRender(delayMs: 100) }
                }

                HStack {
                    Button("Scan Range") {
                        Task { await workspace.scanRange(inSession: session.id, symmetric: false) }
                    }
                    .disabled(session.isScanningRange)

                    Spacer()

                    Button("Scan ±A") {
                        Task { await workspace.scanRange(inSession: session.id, symmetric: true) }
                    }
                    .disabled(session.isScanningRange)
                }
            }

            Section("Labels") {
                TextField("Title", text: binding(\.title))
                TextField("Colorbar label", text: binding(\.colorbarTitle))
                TextField("Missing data (NaN)", text: binding(\.nanColor))
            }

            Section {
                DisclosureGroup("Advanced GMT Options", isExpanded: $advancedExpanded) {
                    Stepper("Title size: \(Int(session.config?.titleSize ?? 14)) pt", value: binding(\.titleSize), in: 6...48)
                    Stepper("Tick size: \(Int(session.config?.annotationSize ?? 10)) pt", value: binding(\.annotationSize), in: 6...36)
                    Stepper("Label size: \(Int(session.config?.labelSize ?? 11)) pt", value: binding(\.labelSize), in: 6...36)

                    HStack {
                        Text("Tick interval X/Y")
                            .foregroundStyle(.secondary)
                        TextField("", value: binding(\.xInterval), format: .number, prompt: Text("Auto"))
                            .labelsHidden()
                            .textFieldStyle(.roundedBorder)
                            .frame(width: 60)
                        TextField("", value: binding(\.yInterval), format: .number, prompt: Text("Auto"))
                            .labelsHidden()
                            .textFieldStyle(.roundedBorder)
                            .frame(width: 60)
                    }

                    TextField("Frame sides", text: binding(\.frameSides))
                    TextField("Coast pen", text: binding(\.coastPen))

                    Picker("Grid resampling", selection: binding(\.interpolation)) {
                        Text("Bicubic").tag("c")
                        Text("Bilinear").tag("l")
                        Text("Nearest neighbor").tag("n")
                        Text("B-spline").tag("b")
                    }

                    Stepper("Preview DPI: \(session.config?.dpi ?? 200)", value: binding(\.dpi), in: 72...600, step: 25)
                    Text("Single-panel and subregion previews auto-boost up to 300 DPI for Retina clarity.")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                    Toggle("Fast preview for large grids", isOn: binding(\.preview))

                    TextField("grdimage args", text: binding(\.extraArgs))
                        .font(.system(.caption, design: .monospaced))
                    TextField("makecpt args", text: binding(\.makecptArgs))
                        .font(.system(.caption, design: .monospaced))
                    TextField("coast args", text: binding(\.coastArgs))
                        .font(.system(.caption, design: .monospaced))
                    TextField("colorbar args", text: binding(\.colorbarArgs))
                        .font(.system(.caption, design: .monospaced))
                    TextField("gmt.conf", text: binding(\.gmtConf))
                        .font(.system(.caption, design: .monospaced))

                    HStack {
                        Button("Plain Frame") {
                            appendGmtConf("MAP_FRAME_TYPE=plain")
                        }
                        Button("D:M:S") {
                            appendGmtConf("FORMAT_GEO_MAP=ddd:mm:ssF")
                        }
                        Spacer()
                        Button("Clear") {
                            session.config?.extraArgs = ""
                            session.config?.makecptArgs = ""
                            session.config?.coastArgs = ""
                            session.config?.colorbarArgs = ""
                            session.config?.gmtConf = ""
                            session.scheduleRender(delayMs: 150)
                        }
                    }
                    .font(.caption)
                }
            }
        }
        .formStyle(.grouped)
    }

    private func appendGmtConf(_ pair: String) {
        guard var conf = session.config?.gmtConf else { return }
        let key = pair.split(separator: "=").first.map(String.init) ?? ""
        var entries = conf.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        entries.removeAll { $0.hasPrefix("\(key)=") }
        entries.append(pair)
        conf = entries.joined(separator: ", ")
        session.config?.gmtConf = conf
        session.scheduleRender(delayMs: 150)
    }

    @ViewBuilder
    private var infoInspectorForm: some View {
        let dataset = workspace.dataset(for: session.datasetPath)
        let variable = workspace.variable(named: session.variableName, inDataset: session.datasetPath)

        if dataset == nil && variable == nil {
            AdaptiveEmptyState(
                "No Metadata",
                systemImage: "info.circle",
                description: "Open a dataset to inspect its dimensions and attributes."
            )
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            Form {
                if let variable {
                    Section("Variable") {
                        LabeledContent("Name", value: variable.name)
                        LabeledContent("Dimensions", value: variable.dimensions.joined(separator: ", "))
                        LabeledContent("Shape", value: variable.shapeSummary)
                        LabeledContent("Type", value: variable.dtype)
                        if let xRange = variable.xRange, xRange.count == 2 {
                            LabeledContent("X Range", value: String(format: "%.4g … %.4g", xRange[0], xRange[1]))
                        }
                        if let yRange = variable.yRange, yRange.count == 2 {
                            LabeledContent("Y Range", value: String(format: "%.4g … %.4g", yRange[0], yRange[1]))
                        }
                        if !variable.unsupportedReason.isEmpty {
                            Text(variable.unsupportedReason)
                                .font(.caption)
                                .foregroundStyle(.orange)
                        }
                    }

                    if !variable.attrs.isEmpty {
                        Section("Variable Attributes") {
                            ForEach(variable.attrs) { attr in
                                LabeledContent(attr.key) {
                                    Text(attr.value)
                                        .foregroundStyle(.secondary)
                                        .multilineTextAlignment(.trailing)
                                        .textSelection(.enabled)
                                }
                            }
                        }
                    }
                }

                if let dataset {
                    Section("Dataset") {
                        LabeledContent("File", value: dataset.fileName)
                        LabeledContent("Path", value: dataset.filePath)
                            .lineLimit(2)
                        ForEach(dataset.dimensions.keys.sorted(), id: \.self) { dim in
                            LabeledContent("dim: \(dim)", value: "\(dataset.dimensions[dim] ?? 0)")
                        }
                    }

                    if !dataset.globalAttrs.isEmpty {
                        Section("Global Attributes") {
                            ForEach(dataset.globalAttrs) { attr in
                                LabeledContent(attr.key) {
                                    Text(attr.value)
                                        .foregroundStyle(.secondary)
                                        .multilineTextAlignment(.trailing)
                                        .textSelection(.enabled)
                                }
                            }
                        }
                    }
                }
            }
            .formStyle(.grouped)
        }
    }
}
