import SwiftUI

struct PlotInspectorView: View {
    @ObservedObject var workspace: WorkspaceManager
    @ObservedObject var session: PlotSession

    @State private var advancedExpanded = false
    @State private var customProjectionText = ""
    @State private var customCptText = ""
    @State private var centerLonText = ""
    @State private var levelsText = "16"

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
            centerLonText = ProjectionCenterHelper.formattedCentralMeridian(from: newValue ?? "")
        }
        .onChange(of: session.config?.cpt) { newValue in
            customCptText = newValue ?? ""
        }
        .onChange(of: session.config?.cptLevels) { newValue in
            if let newValue {
                levelsText = "\(newValue)"
            }
        }
        .onAppear {
            customProjectionText = session.config?.projection ?? ""
            centerLonText = ProjectionCenterHelper.formattedCentralMeridian(from: session.config?.projection ?? "")
            customCptText = session.config?.cpt ?? ""
            levelsText = "\(session.config?.cptLevels ?? 16)"
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
        let isGeo = session.config?.isGeographic ?? true
        let currentProj = session.config?.projection ?? ""
        Form {
            Section("Projection") {
                if isGeo {
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
                }

                let options = session.recommendedProjections
                Picker("Preset", selection: Binding(
                    get: { currentProj },
                    set: { newCode in
                        session.config?.projection = newCode
                        session.config?.projectionMode = "manual"
                        customProjectionText = newCode
                        centerLonText = ProjectionCenterHelper.formattedCentralMeridian(from: newCode)
                        session.scheduleRender(delayMs: 250)
                    }
                )) {
                    ForEach(options) { opt in
                        Text(opt.label).tag(opt.code)
                    }
                    if !currentProj.isEmpty,
                       !options.contains(where: { $0.code == currentProj }) {
                        Text("Custom (\(currentProj))").tag(currentProj)
                    }
                }

                if isGeo && ProjectionCenterHelper.supportsCentralMeridian(currentProj) {
                    let currentLon0 = ProjectionCenterHelper.extractCentralMeridian(from: currentProj)
                    HStack(spacing: 6) {
                        Text("Center Lon")
                            .foregroundStyle(.secondary)
                        Spacer(minLength: 4)
                        Button("0°") {
                            applyCenterLon(0.0)
                        }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                        .tint(currentLon0.map { abs($0) < 1e-6 } == true ? .accentColor : nil)

                        Button("180°") {
                            applyCenterLon(180.0)
                        }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                        .tint(currentLon0.map { abs(abs($0) - 180.0) < 1e-6 } == true ? .accentColor : nil)

                        TextField("", text: $centerLonText, prompt: Text("lon0"))
                            .labelsHidden()
                            .textFieldStyle(.roundedBorder)
                            .font(.caption.monospacedDigit())
                            .frame(width: 56)
                            .onSubmit {
                                let cleaned = centerLonText
                                    .trimmingCharacters(in: .whitespacesAndNewlines)
                                    .replacingOccurrences(of: "°", with: "")
                                if let val = Double(cleaned), val.isFinite, (-360.0...360.0).contains(val) {
                                    applyCenterLon(val)
                                }
                            }
                    }
                }

                HStack {
                    Text("GMT -J")
                        .foregroundStyle(.secondary)
                    TextField("", text: $customProjectionText, prompt: Text(isGeo ? "e.g. M16c" : "e.g. X16c/10c"))
                        .labelsHidden()
                        .textFieldStyle(.roundedBorder)
                        .font(.system(.body, design: .monospaced))
                        .onSubmit {
                            let code = customProjectionText.trimmingCharacters(in: .whitespacesAndNewlines)
                                .replacingOccurrences(of: "^-J", with: "", options: .regularExpression)
                            guard !code.isEmpty else { return }
                            session.config?.projection = code
                            session.config?.projectionMode = "manual"
                            centerLonText = ProjectionCenterHelper.formattedCentralMeridian(from: code)
                            session.scheduleRender(delayMs: 100)
                        }
                }
            }

            Section(isGeo ? "Region (-R)" : "Data Bounds (-R)") {
                Grid(horizontalSpacing: 10, verticalSpacing: 8) {
                    GridRow {
                        boundField(isGeo ? "W" : "X min", index: 0)
                        boundField(isGeo ? "E" : "X max", index: 1)
                    }
                    GridRow {
                        boundField(isGeo ? "S" : "Y min", index: 2)
                        boundField(isGeo ? "N" : "Y max", index: 3)
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

            Section(isGeo ? "Overlays & Masking" : "Frame & Colorbar") {
                if isGeo {
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
                }

                Toggle("Frame & tick labels", isOn: binding(\.showFrame))
                Toggle("Gridlines", isOn: binding(\.showGrid))
                Toggle("Colorbar", isOn: binding(\.showColorbar))

                if isGeo {
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
        }
        .formStyle(.grouped)
    }

    private func applyCenterLon(_ lon0: Double) {
        guard var cfg = session.config else { return }
        let updatedProj = ProjectionCenterHelper.applyingCentralMeridian(lon0, to: cfg.projection)
        cfg.projection = updatedProj
        cfg.projectionMode = "manual"
        cfg.region = ProjectionCenterHelper.shiftedGlobalRegion(cfg.region, lon0: lon0)
        session.config = cfg
        customProjectionText = updatedProj
        centerLonText = ProjectionCenterHelper.formattedCentralMeridian(from: updatedProj)
        session.scheduleRender(delayMs: 120)
    }

    @ViewBuilder
    private func boundField(_ label: String, index: Int) -> some View {
        HStack(spacing: 5) {
            Text(label)
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
                .frame(width: label.count > 2 ? 38 : 16, alignment: .leading)
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

                let modeTag = (session.config?.cptCategorical == true) ? "categorical" : ((session.config?.cptContinuous ?? true) ? "continuous" : "discrete")
                Picker("Mode", selection: Binding(
                    get: { modeTag },
                    set: { mode in
                        guard session.config != nil else { return }
                        if mode == "categorical" {
                            session.config?.cptCategorical = true
                            session.config?.cptContinuous = false
                            session.config?.interpolation = "n"
                            if let cur = session.config?.cpt, ["turbo", "rainbow", "panoply"].contains(cur) {
                                session.config?.cpt = "categorical"
                                customCptText = "categorical"
                            }
                        } else if mode == "discrete" {
                            session.config?.cptCategorical = false
                            session.config?.cptContinuous = false
                        } else {
                            session.config?.cptCategorical = false
                            session.config?.cptContinuous = true
                        }
                        session.scheduleRender(delayMs: 200)
                    }
                )) {
                    Text("Continuous").tag("continuous")
                    Text("Discrete").tag("discrete")
                    Text("Categorical").tag("categorical")
                }
                .pickerStyle(.menu)

                if session.config?.cptCategorical == false && session.config?.cptContinuous == false {
                    HStack(spacing: 8) {
                        Text("Levels")
                            .foregroundStyle(.secondary)
                        Spacer(minLength: 4)
                        TextField("", text: $levelsText, prompt: Text("2–256"))
                            .labelsHidden()
                            .textFieldStyle(.roundedBorder)
                            .font(.caption.monospacedDigit())
                            .multilineTextAlignment(.trailing)
                            .frame(width: 56)
                            .onSubmit {
                                if let raw = Int(levelsText.trimmingCharacters(in: .whitespacesAndNewlines)) {
                                    let clamped = min(256, max(2, raw))
                                    levelsText = "\(clamped)"
                                    session.config?.cptLevels = clamped
                                    session.scheduleRender(delayMs: 120)
                                } else {
                                    levelsText = "\(session.config?.cptLevels ?? 16)"
                                }
                            }
                        Stepper(
                            "",
                            value: Binding(
                                get: { session.config?.cptLevels ?? 16 },
                                set: { newVal in
                                    let clamped = min(256, max(2, newVal))
                                    levelsText = "\(clamped)"
                                    session.config?.cptLevels = clamped
                                    session.scheduleRender(delayMs: 250)
                                }
                            ),
                            in: 2...256
                        )
                        .labelsHidden()
                    }
                }

                Toggle("Reverse palette (-Ic)", isOn: binding(\.cptReverse))
            }

            if session.config?.cptCategorical == true {
                let count = session.config?.flagValues.count ?? 0
                Section("Categorical Flags") {
                    Text(count > 0
                         ? "Auto-assigning discrete colors for \(count) CF flag values with nearest-neighbor interpolation (-nn)."
                         : "Assigning distinct qualitative colors per unique value with nearest-neighbor interpolation (-nn).")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            } else {
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
        let activeTarget: InspectTarget? = session.inspectedTarget ?? {
            guard let path = session.datasetPath else { return nil }
            if let vname = session.variableName {
                return .variable(datasetPath: path, variableName: vname)
            }
            return .dataset(path)
        }()
        let dataset = workspace.dataset(for: activeTarget?.datasetPath)
        let variable = workspace.variable(named: activeTarget?.variableName, inDataset: activeTarget?.datasetPath)

        if dataset == nil && variable == nil {
            AdaptiveEmptyState(
                "No Metadata",
                systemImage: "info.circle",
                description: "Click a file or variable in the sidebar to inspect its structure and attributes."
            )
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            Form {
                if let dataset {
                    Section {
                        VStack(alignment: .leading, spacing: 8) {
                            HStack(spacing: 6) {
                                Image(systemName: variable != nil ? "cube" : "doc.text")
                                    .foregroundStyle(Color.accentColor)
                                Text(variable?.name ?? dataset.fileName)
                                    .font(.headline)
                                    .lineLimit(1)
                                Spacer(minLength: 4)
                                if let variable,
                                   session.datasetPath == dataset.filePath,
                                   session.variableName == variable.name {
                                    Text("Plotted")
                                        .font(.caption2.weight(.medium))
                                        .padding(.horizontal, 6)
                                        .padding(.vertical, 2)
                                        .background(Color.accentColor.opacity(0.15), in: Capsule())
                                        .foregroundStyle(Color.accentColor)
                                }
                            }

                            if let variable, !variable.displayTitle.isEmpty, variable.displayTitle != variable.name {
                                Text(variable.displayTitle)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }

                            HStack(spacing: 6) {
                                if let variable, variable.is2DPlotable {
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

                                    Button("New Tab") {
                                        Task {
                                            await workspace.selectVariable(
                                                datasetPath: dataset.filePath,
                                                varName: variable.name,
                                                inSession: session.id,
                                                openInNewTab: true
                                            )
                                        }
                                    }
                                    .buttonStyle(.bordered)
                                    .controlSize(.small)
                                }

                                Button("CDL / Structure…") {
                                    workspace.openStructureSheet(datasetPath: dataset.filePath, inSession: session.id)
                                }
                                .buttonStyle(.bordered)
                                .controlSize(.small)

                                if let plottedPath = session.datasetPath,
                                   let plottedVar = session.variableName,
                                   (plottedPath != activeTarget?.datasetPath || plottedVar != activeTarget?.variableName) {
                                    Button("Active Plot") {
                                        workspace.inspectVariable(
                                            datasetPath: plottedPath,
                                            varName: plottedVar,
                                            inSession: session.id,
                                            switchToInfoTab: true
                                        )
                                    }
                                    .buttonStyle(.borderless)
                                    .controlSize(.small)
                                }
                            }
                        }
                        .padding(.vertical, 2)
                    }
                }

                if let variable {
                    Section("Variable Summary") {
                        LabeledContent("Dimensions", value: variable.dimensions.joined(separator: ", "))
                        LabeledContent("Shape", value: variable.shapeSummary)
                        LabeledContent("Type", value: variable.dtype)
                        if !variable.units.isEmpty {
                            LabeledContent("Units", value: variable.units)
                        }
                        if let xRange = variable.xRange, xRange.count == 2 {
                            LabeledContent(variable.isGeographic ? "Lon Range" : "X Range", value: String(format: "%.4g … %.4g", xRange[0], xRange[1]))
                        }
                        if let yRange = variable.yRange, yRange.count == 2 {
                            LabeledContent(variable.isGeographic ? "Lat Range" : "Y Range", value: String(format: "%.4g … %.4g", yRange[0], yRange[1]))
                        }
                        if !variable.unsupportedReason.isEmpty {
                            Text(variable.unsupportedReason)
                                .font(.caption)
                                .foregroundStyle(.orange)
                        }
                    }

                    if !variable.flagValues.isEmpty {
                        Section("Flag Definitions (\(variable.flagValues.count))") {
                            ForEach(Array(variable.flagValues.enumerated()), id: \.offset) { idx, fval in
                                let keyText = abs(fval - fval.rounded()) < 1e-6 ? String(Int(fval.rounded())) : String(format: "%.4g", fval)
                                let meaning = idx < variable.flagMeanings.count ? variable.flagMeanings[idx].replacingOccurrences(of: "_", with: " ") : ""
                                HStack(alignment: .top, spacing: 8) {
                                    Text(keyText)
                                        .font(.caption.monospacedDigit().weight(.semibold))
                                        .padding(.horizontal, 6)
                                        .padding(.vertical, 2)
                                        .background(.quaternary.opacity(0.6), in: RoundedRectangle(cornerRadius: 4))
                                    Text(meaning.isEmpty ? "Class \(keyText)" : meaning)
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                        .frame(maxWidth: .infinity, alignment: .leading)
                                        .textSelection(.enabled)
                                }
                            }
                        }
                    }

                    if !variable.attrs.isEmpty {
                        Section("Variable Attributes") {
                            ForEach(variable.attrs) { attr in
                                stackedAttrRow(key: attr.key, value: attr.value)
                            }
                        }
                    }
                }

                if let dataset {
                    Section("Dataset") {
                        LabeledContent("File", value: dataset.fileName)
                        stackedAttrRow(key: "Path", value: dataset.filePath)
                        LabeledContent("Variables", value: "\(dataset.plotableVariables.count) plottable · \(dataset.nonPlotableVariables.count) other")
                        ForEach(dataset.dimensions.keys.sorted(), id: \.self) { dim in
                            LabeledContent("dim: \(dim)", value: "\(dataset.dimensions[dim] ?? 0)")
                        }
                    }

                    if variable == nil && !dataset.variables.isEmpty {
                        Section("Variables (\(dataset.variables.count))") {
                            ForEach(dataset.variables) { item in
                                HStack(spacing: 8) {
                                    Button {
                                        workspace.inspectVariable(
                                            datasetPath: dataset.filePath,
                                            varName: item.name,
                                            inSession: session.id,
                                            switchToInfoTab: true
                                        )
                                    } label: {
                                        VStack(alignment: .leading, spacing: 1) {
                                            Text(item.name)
                                                .font(.caption.weight(.medium))
                                                .foregroundStyle(item.is2DPlotable ? .primary : .secondary)
                                            Text("\(item.dtype) [\(item.shapeSummary)]\(item.units.isEmpty ? "" : " · \(item.units)")")
                                                .font(.caption2)
                                                .foregroundStyle(.secondary)
                                                .lineLimit(1)
                                        }
                                        .frame(maxWidth: .infinity, alignment: .leading)
                                        .contentShape(Rectangle())
                                    }
                                    .buttonStyle(.plain)

                                    if item.is2DPlotable {
                                        Button("Plot") {
                                            Task {
                                                await workspace.selectVariable(
                                                    datasetPath: dataset.filePath,
                                                    varName: item.name,
                                                    inSession: session.id,
                                                    openInNewTab: false
                                                )
                                            }
                                        }
                                        .buttonStyle(.bordered)
                                        .controlSize(.mini)
                                    }
                                }
                            }
                        }
                    }

                    if !dataset.globalAttrs.isEmpty {
                        Section("Global Attributes") {
                            ForEach(dataset.globalAttrs) { attr in
                                stackedAttrRow(key: attr.key, value: attr.value)
                            }
                        }
                    }
                }
            }
            .formStyle(.grouped)
        }
    }

    @ViewBuilder
    private func stackedAttrRow(key: String, value: String) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(key)
                .font(.caption.weight(.semibold))
                .foregroundStyle(.primary)
            Text(value)
                .font(.caption)
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)
                .fixedSize(horizontal: false, vertical: true)
                .textSelection(.enabled)
        }
        .padding(.vertical, 1)
    }
}
