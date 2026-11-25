import Foundation
import SwiftUI

enum InspectorTab: String, CaseIterable, Identifiable, Sendable {
    case map = "Map"
    case style = "Style"
    case info = "Info"

    var id: String { rawValue }
}

struct CNBorderStatus: Codable, Sendable, Equatable {
    let installed: Bool
    let l1Path: String?
    let laPath: String?
    let defaultDir: String

    enum CodingKeys: String, CodingKey {
        case installed
        case l1Path = "l1_path"
        case laPath = "la_path"
        case defaultDir = "default_dir"
    }
}

struct ServerInfo: Codable, Sendable, Equatable {
    let version: String
    let gmtVersion: String
    let gmtBin: String
    let gsBin: String?
    let python: String

    enum CodingKeys: String, CodingKey {
        case version
        case gmtVersion = "gmt_version"
        case gmtBin = "gmt_bin"
        case gsBin = "gs_bin"
        case python
    }
}

struct KeyValueAttr: Codable, Sendable, Equatable, Identifiable {
    let key: String
    let value: String

    var id: String { key }

    init(key: String, value: String) {
        self.key = key
        self.value = value
    }

    init(from decoder: Decoder) throws {
        var container = try decoder.unkeyedContainer()
        self.key = try container.decode(String.self)
        self.value = try container.decode(String.self)
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.unkeyedContainer()
        try container.encode(key)
        try container.encode(value)
    }
}

struct VarMeta: Codable, Sendable, Equatable, Identifiable {
    let name: String
    let displayTitle: String
    let dimensions: [String]
    let shape: [Int]
    let dtype: String
    let attrs: [KeyValueAttr]
    let is2DPlotable: Bool
    let xDim: String?
    let yDim: String?
    let sliceDims: [String]
    let isGeographic: Bool
    let unsupportedReason: String
    let xRange: [Double]?
    let yRange: [Double]?
    let vRange: [Double]?
    let flagValues: [Double]
    let flagMeanings: [String]
    let isCategorical: Bool
    let defaultCpt: String
    let defaultSymmetric: Bool

    var id: String { name }

    var units: String {
        attrs.first(where: { $0.key == "units" })?.value ?? ""
    }

    var shapeSummary: String {
        shape.map(String.init).joined(separator: " × ")
    }

    var attrsDictionary: [String: String] {
        Dictionary(attrs.map { ($0.key, $0.value) }, uniquingKeysWith: { first, _ in first })
    }

    enum CodingKeys: String, CodingKey {
        case name
        case displayTitle = "display_title"
        case dimensions
        case shape
        case dtype
        case attrs
        case is2DPlotable = "is_2d_plotable"
        case xDim = "x_dim"
        case yDim = "y_dim"
        case sliceDims = "slice_dims"
        case isGeographic = "is_geographic"
        case unsupportedReason = "unsupported_reason"
        case xRange = "x_range"
        case yRange = "y_range"
        case vRange = "v_range"
        case flagValues = "flag_values"
        case flagMeanings = "flag_meanings"
        case isCategorical = "is_categorical"
        case defaultCpt = "default_cpt"
        case defaultSymmetric = "default_symmetric"
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        name = try c.decode(String.self, forKey: .name)
        displayTitle = try c.decode(String.self, forKey: .displayTitle)
        dimensions = try c.decode([String].self, forKey: .dimensions)
        shape = try c.decode([Int].self, forKey: .shape)
        dtype = try c.decode(String.self, forKey: .dtype)
        attrs = try c.decode([KeyValueAttr].self, forKey: .attrs)
        is2DPlotable = try c.decode(Bool.self, forKey: .is2DPlotable)
        xDim = try c.decodeIfPresent(String.self, forKey: .xDim)
        yDim = try c.decodeIfPresent(String.self, forKey: .yDim)
        sliceDims = try c.decode([String].self, forKey: .sliceDims)
        isGeographic = try c.decode(Bool.self, forKey: .isGeographic)
        unsupportedReason = try c.decode(String.self, forKey: .unsupportedReason)
        xRange = try c.decodeIfPresent([Double].self, forKey: .xRange)
        yRange = try c.decodeIfPresent([Double].self, forKey: .yRange)
        vRange = try c.decodeIfPresent([Double].self, forKey: .vRange)
        flagValues = try c.decodeIfPresent([Double].self, forKey: .flagValues) ?? []
        flagMeanings = try c.decodeIfPresent([String].self, forKey: .flagMeanings) ?? []
        isCategorical = try c.decodeIfPresent(Bool.self, forKey: .isCategorical) ?? false
        defaultCpt = try c.decode(String.self, forKey: .defaultCpt)
        defaultSymmetric = try c.decode(Bool.self, forKey: .defaultSymmetric)
    }
}

struct DatasetMeta: Codable, Sendable, Equatable, Identifiable {
    let filePath: String
    let fileName: String
    let dimensions: [String: Int]
    let dimensionCoords: [String: [String]]
    let globalAttrs: [KeyValueAttr]
    let variables: [VarMeta]

    var id: String { filePath }

    var plotableVariables: [VarMeta] {
        variables.filter(\.is2DPlotable)
    }

    var nonPlotableVariables: [VarMeta] {
        variables.filter { !$0.is2DPlotable }
    }

    enum CodingKeys: String, CodingKey {
        case filePath = "file_path"
        case fileName = "file_name"
        case dimensions
        case dimensionCoords = "dimension_coords"
        case globalAttrs = "global_attrs"
        case variables
    }
}

struct ProjectionOption: Codable, Sendable, Equatable, Identifiable {
    let label: String
    let code: String
    let category: String

    var id: String { code }
}

struct PlotConfig: Codable, Sendable, Equatable {
    var gridSpec: String = ""
    var region: [Double]? = nil
    var projection: String = "Q16c"
    var cpt: String = "turbo"
    var cptRange: [Double]? = nil
    var cptReverse: Bool = false
    var cptContinuous: Bool = true
    var maskMode: String = "none"
    var maskColor: String = "gray90"
    var showCoast: Bool = true
    var showBorders: Bool = false
    var showGrid: Bool = true
    var showColorbar: Bool = true
    var colorbarTitle: String = ""
    var dpi: Int = 200
    var title: String = ""
    var extraArgs: String = ""
    var gmtConf: String = ""
    var projectionMode: String = "auto"
    var isGeographic: Bool = true
    var sourcePath: String = ""
    var variableName: String = ""
    var variableDescription: String = ""
    var sliceIndices: [String: Int] = [:]
    var showFrame: Bool = true
    var frameSides: String = "WSen"
    var xInterval: Double = 0.0
    var yInterval: Double = 0.0
    var titleSize: Double = 14.0
    var annotationSize: Double = 10.0
    var labelSize: Double = 11.0
    var symmetricCpt: Bool = false
    var cptLevels: Int = 16
    var cptCategorical: Bool = false
    var flagValues: [Double] = []
    var flagMeanings: [String] = []
    var coastResolution: String = "l"
    var coastPen: String = "0.4p,gray25"
    var interpolation: String = "c"
    var nanColor: String = "gray90"
    var preview: Bool = true
    var makecptArgs: String = ""
    var coastArgs: String = ""
    var colorbarArgs: String = ""
    var borderMode: String = "none"
    var borderPen: String = "0.5p,gray25"
    var cnBorderDir: String = ""

    enum CodingKeys: String, CodingKey {
        case gridSpec = "grid_spec"
        case region
        case projection
        case cpt
        case cptRange = "cpt_range"
        case cptReverse = "cpt_reverse"
        case cptContinuous = "cpt_continuous"
        case maskMode = "mask_mode"
        case maskColor = "mask_color"
        case showCoast = "show_coast"
        case showBorders = "show_borders"
        case showGrid = "show_grid"
        case showColorbar = "show_colorbar"
        case colorbarTitle = "colorbar_title"
        case dpi
        case title
        case extraArgs = "extra_args"
        case gmtConf = "gmt_conf"
        case projectionMode = "projection_mode"
        case isGeographic = "is_geographic"
        case sourcePath = "source_path"
        case variableName = "variable_name"
        case variableDescription = "variable_description"
        case sliceIndices = "slice_indices"
        case showFrame = "show_frame"
        case frameSides = "frame_sides"
        case xInterval = "x_interval"
        case yInterval = "y_interval"
        case titleSize = "title_size"
        case annotationSize = "annotation_size"
        case labelSize = "label_size"
        case symmetricCpt = "symmetric_cpt"
        case cptLevels = "cpt_levels"
        case cptCategorical = "cpt_categorical"
        case flagValues = "flag_values"
        case flagMeanings = "flag_meanings"
        case coastResolution = "coast_resolution"
        case coastPen = "coast_pen"
        case interpolation
        case nanColor = "nan_color"
        case preview
        case makecptArgs = "makecpt_args"
        case coastArgs = "coast_args"
        case colorbarArgs = "colorbar_args"
        case borderMode = "border_mode"
        case borderPen = "border_pen"
        case cnBorderDir = "cn_border_dir"
    }

    /// Signature of all non-region / non-projection visual parameters for Breadcrumb cache validation.
    var styleSignature: String {
        var copy = self
        copy.region = nil
        copy.projection = ""
        copy.projectionMode = ""
        copy.title = ""
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let data = (try? encoder.encode(copy)) ?? Data()
        return String(data: data, encoding: .utf8) ?? ""
    }

    static func defaultConfig(
        for variable: VarMeta,
        dataset: DatasetMeta,
        previewLOD: Bool,
        previewDPI: Int,
        recommendedProjection: String? = nil
    ) -> PlotConfig {
        let region: [Double]? = {
            if let x = variable.xRange, let y = variable.yRange, x.count == 2, y.count == 2 {
                return [x[0], x[1], y[0], y[1]]
            }
            return nil
        }()
        var slices: [String: Int] = [:]
        for dim in variable.sliceDims {
            slices[dim] = 0
        }
        let attrs = variable.attrsDictionary
        let desc = ["standard_name", "long_name", "units", "comment", "description"]
            .compactMap { attrs[$0] }
            .joined(separator: " ")

        return PlotConfig(
            gridSpec: "",
            region: region,
            projection: recommendedProjection ?? (variable.isGeographic ? "Q16c" : "X16c/10c"),
            cpt: variable.defaultCpt,
            cptRange: nil,
            cptContinuous: !variable.isCategorical,
            colorbarTitle: variable.units,
            dpi: previewDPI,
            title: variable.displayTitle,
            projectionMode: variable.isGeographic ? "auto" : "manual",
            isGeographic: variable.isGeographic,
            sourcePath: dataset.filePath,
            variableName: variable.name,
            variableDescription: desc,
            sliceIndices: slices,
            symmetricCpt: variable.defaultSymmetric,
            cptCategorical: variable.isCategorical,
            flagValues: variable.flagValues,
            flagMeanings: variable.flagMeanings,
            interpolation: variable.isCategorical ? "n" : "c",
            preview: previewLOD
        )
    }
}

struct RenderResult: Codable, Sendable, Equatable {
    let imagePath: String
    let resolvedConfig: PlotConfig
    let mapBbox: [Double]?
    let dimsCm: [Double]?
    let hoverGridSize: Int
    let hoverB64: String?
    let elapsedSec: Double

    enum CodingKeys: String, CodingKey {
        case imagePath = "image_path"
        case resolvedConfig = "resolved_config"
        case mapBbox = "map_bbox"
        case dimsCm = "dims_cm"
        case hoverGridSize = "hover_grid_size"
        case hoverB64 = "hover_b64"
        case elapsedSec = "elapsed_sec"
    }
}

struct RangeResult: Codable, Sendable, Equatable {
    let zMin: Double
    let zMax: Double

    enum CodingKeys: String, CodingKey {
        case zMin = "z_min"
        case zMax = "z_max"
    }
}

struct ScriptRunResult: Codable, Sendable, Equatable {
    let imagePath: String?
    let parsedConfig: PlotConfig?
    let stdout: String
    let stderr: String

    enum CodingKeys: String, CodingKey {
        case imagePath = "image_path"
        case parsedConfig = "parsed_config"
        case stdout
        case stderr
    }
}

struct HoverGrid: Sendable, Equatable {
    let size: Int
    let coords: [Float]

    init?(base64: String?, size: Int) {
        guard let base64, size >= 2, let data = Data(base64Encoded: base64) else {
            return nil
        }
        let floatCount = size * size * 2
        guard data.count == floatCount * MemoryLayout<Float>.size else {
            return nil
        }
        var decoded = [Float](repeating: 0, count: floatCount)
        data.withUnsafeBytes { rawBuffer in
            for idx in 0..<floatCount {
                let offset = idx * 4
                let b0 = UInt32(rawBuffer[offset])
                let b1 = UInt32(rawBuffer[offset + 1]) << 8
                let b2 = UInt32(rawBuffer[offset + 2]) << 16
                let b3 = UInt32(rawBuffer[offset + 3]) << 24
                decoded[idx] = Float(bitPattern: b0 | b1 | b2 | b3)
            }
        }
        self.size = size
        self.coords = decoded
    }

    func coordinate(u: Double, v: Double) -> (lon: Double, lat: Double)? {
        guard size >= 2, u >= 0, u <= 1, v >= 0, v <= 1 else {
            return nil
        }
        let maxIndex = Double(size - 1)
        let x = u * maxIndex
        let y = v * maxIndex
        let i = min(max(0, Int(x)), size - 2)
        let j = min(max(0, Int(y)), size - 2)

        func pair(_ row: Int, _ col: Int) -> (Double, Double) {
            let base = (row * size + col) * 2
            return (Double(coords[base]), Double(coords[base + 1]))
        }

        let p00 = pair(j, i)
        let p01 = pair(j, i + 1)
        let p10 = pair(j + 1, i)
        let p11 = pair(j + 1, i + 1)

        let lons = [p00.0, p01.0, p10.0, p11.0]
        let lats = [p00.1, p01.1, p10.1, p11.1]
        guard lons.allSatisfy(\.isFinite), lats.allSatisfy(\.isFinite) else {
            return nil
        }
        if let minLon = lons.min(), let maxLon = lons.max(), (maxLon - minLon) > 90.0 {
            return nil
        }

        let a = x - Double(i)
        let b = y - Double(j)
        let lon = (1.0 - b) * ((1.0 - a) * p00.0 + a * p01.0) + b * ((1.0 - a) * p10.0 + a * p11.0)
        let lat = (1.0 - b) * ((1.0 - a) * p00.1 + a * p01.1) + b * ((1.0 - a) * p10.1 + a * p11.1)
        guard lon.isFinite, lat.isFinite else { return nil }
        return (lon, lat)
    }
}

enum GMTColorPalettes {
    static let builtInNames: [String] = [
        "panoply", "turbo", "rainbow", "seis", "polar",
        "jet", "vik", "roma", "batlow", "viridis",
        "plasma", "magma", "inferno", "relief", "topo",
        "ocean", "gray", "categorical"
    ]

    static func gradient(for name: String) -> LinearGradient {
        let stops: [Color]
        switch name.lowercased() {
        case "panoply":
            stops = [Color(red: 0.03, green: 0.14, blue: 0.65), .blue, .cyan, .green, .yellow, .orange, .red]
        case "turbo":
            stops = [Color(red: 0.19, green: 0.07, blue: 0.23), .blue, .cyan, .green, .yellow, .orange, .red]
        case "rainbow":
            stops = [.purple, .blue, .cyan, .green, .yellow, .orange, .red]
        case "seis":
            stops = [Color(red: 0.65, green: 0.0, blue: 0.13), .orange, .yellow, .white, .cyan, .blue]
        case "polar":
            stops = [Color(red: 0.05, green: 0.25, blue: 0.75), .cyan, .white, .orange, Color(red: 0.75, green: 0.1, blue: 0.1)]
        case "jet":
            stops = [Color(red: 0.0, green: 0.0, blue: 0.5), .blue, .cyan, .yellow, .red, Color(red: 0.5, green: 0.0, blue: 0.0)]
        case "vik":
            stops = [Color(red: 0.0, green: 0.07, blue: 0.38), Color(red: 0.27, green: 0.58, blue: 0.8), .white, Color(red: 0.78, green: 0.35, blue: 0.18), Color(red: 0.35, green: 0.0, blue: 0.03)]
        case "roma":
            stops = [Color(red: 0.49, green: 0.09, blue: 0.04), .orange, Color(red: 0.85, green: 0.92, blue: 0.65), .teal, Color(red: 0.08, green: 0.2, blue: 0.48)]
        case "batlow":
            stops = [Color(red: 0.01, green: 0.1, blue: 0.35), Color(red: 0.11, green: 0.35, blue: 0.38), Color(red: 0.49, green: 0.51, blue: 0.2), Color(red: 0.9, green: 0.61, blue: 0.48), Color(red: 0.99, green: 0.81, blue: 0.8)]
        case "viridis":
            stops = [Color(red: 0.27, green: 0.0, blue: 0.33), Color(red: 0.19, green: 0.41, blue: 0.56), Color(red: 0.21, green: 0.72, blue: 0.47), Color(red: 0.99, green: 0.91, blue: 0.15)]
        case "plasma":
            stops = [Color(red: 0.05, green: 0.03, blue: 0.53), Color(red: 0.49, green: 0.01, blue: 0.66), Color(red: 0.8, green: 0.28, blue: 0.47), Color(red: 0.97, green: 0.58, blue: 0.25), Color(red: 0.94, green: 0.98, blue: 0.13)]
        case "relief", "topo":
            stops = [Color(red: 0.05, green: 0.22, blue: 0.55), Color(red: 0.25, green: 0.62, blue: 0.85), Color(red: 0.2, green: 0.62, blue: 0.3), Color(red: 0.85, green: 0.75, blue: 0.45), .white]
        case "ocean":
            stops = [Color(red: 0.02, green: 0.06, blue: 0.22), Color(red: 0.04, green: 0.25, blue: 0.52), Color(red: 0.13, green: 0.55, blue: 0.75), Color(red: 0.58, green: 0.88, blue: 0.92)]
        case "magma":
            stops = [.black, Color(red: 0.32, green: 0.07, blue: 0.49), Color(red: 0.72, green: 0.21, blue: 0.47), Color(red: 0.99, green: 0.54, blue: 0.38), Color(red: 0.99, green: 0.99, blue: 0.75)]
        case "inferno":
            stops = [.black, Color(red: 0.34, green: 0.06, blue: 0.43), Color(red: 0.73, green: 0.21, blue: 0.33), Color(red: 0.98, green: 0.55, blue: 0.04), Color(red: 0.99, green: 1.0, blue: 0.64)]
        case "gray":
            stops = [.black, .gray, .white]
        case "categorical":
            stops = [
                Color(red: 0.12, green: 0.47, blue: 0.71),
                Color(red: 1.00, green: 0.50, blue: 0.05),
                Color(red: 0.17, green: 0.63, blue: 0.17),
                Color(red: 0.84, green: 0.15, blue: 0.16),
                Color(red: 0.58, green: 0.40, blue: 0.74),
                Color(red: 0.09, green: 0.75, blue: 0.81),
            ]
        default:
            stops = [.indigo, .blue, .teal, .orange, .red]
        }
        return LinearGradient(colors: stops, startPoint: .leading, endPoint: .trailing)
    }
}

enum ProjectionCenterHelper {
    private static let singlePrefixes: Set<Character> = [
        "W", "R", "H", "N", "I", "Q", "M", "G", "A", "S", "T", "E", "F", "C", "L", "B"
    ]

    private static func splitPrefixAndBody(_ code: String) -> (prefix: String, body: String)? {
        let trimmed = code.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed != "IntMollOcean" else { return nil }
        let upper = trimmed.uppercased()
        if upper.hasPrefix("KF") || upper.hasPrefix("KS") {
            return (String(trimmed.prefix(2)), String(trimmed.dropFirst(2)))
        }
        if let first = upper.first, first != "X", singlePrefixes.contains(first) {
            return (String(trimmed.prefix(1)), String(trimmed.dropFirst(1)))
        }
        return nil
    }

    static func supportsCentralMeridian(_ code: String) -> Bool {
        splitPrefixAndBody(code) != nil
    }

    static func extractCentralMeridian(from code: String) -> Double? {
        guard let (_, body) = splitPrefixAndBody(code) else { return nil }
        let parts = body.split(separator: "/", omittingEmptySubsequences: false)
        guard parts.count >= 2 else { return nil }
        return Double(parts[0])
    }

    static func formattedCentralMeridian(from code: String) -> String {
        guard let lon0 = extractCentralMeridian(from: code) else { return "" }
        if abs(lon0 - lon0.rounded()) < 1e-6 {
            return String(Int(lon0.rounded()))
        }
        return String(format: "%.4g", lon0)
    }

    static func applyingCentralMeridian(_ lon0: Double, to code: String) -> String {
        guard let (prefix, body) = splitPrefixAndBody(code) else { return code }
        let lonStr = abs(lon0 - lon0.rounded()) < 1e-6 ? String(Int(lon0.rounded())) : String(format: "%.6g", lon0)
        var parts = body.split(separator: "/", omittingEmptySubsequences: false).map(String.init)
        guard !parts.isEmpty else { return code }
        if parts.count == 1 {
            return "\(prefix)\(lonStr)/\(parts[0])"
        }
        parts[0] = lonStr
        return prefix + parts.joined(separator: "/")
    }

    static func shiftedGlobalRegion(_ region: [Double]?, lon0: Double) -> [Double]? {
        guard let region, region.count == 4, (region[1] - region[0]) >= 359.0 else {
            return region
        }
        let s = region[2]
        let n = region[3]
        if abs(lon0) < 1e-6 {
            return [-180.0, 180.0, s, n]
        }
        if abs(abs(lon0) - 180.0) < 1e-6 {
            return [0.0, 360.0, s, n]
        }
        return [lon0 - 180.0, lon0 + 180.0, s, n]
    }
}
