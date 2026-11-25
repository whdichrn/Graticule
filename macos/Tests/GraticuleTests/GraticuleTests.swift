import Foundation
import XCTest
@testable import Graticule

final class GraticuleTests: XCTestCase {
    func testHoverGridDecodeAndBilinearInterpolation() {
        // 2x2 grid:
        // j=0 (v=0): (10, -20), (20, -20)
        // j=1 (v=1): (10, 0),   (20, 0)
        let floats: [Float] = [
            10, -20, 20, -20,
            10,   0, 20,   0
        ]
        var data = Data()
        for val in floats {
            var le = val.bitPattern.littleEndian
            withUnsafeBytes(of: &le) { data.append(contentsOf: $0) }
        }
        let b64 = data.base64EncodedString()
        guard let grid = HoverGrid(base64: b64, size: 2) else {
            XCTFail("Expected HoverGrid to decode")
            return
        }

        let center = grid.coordinate(u: 0.5, v: 0.5)
        XCTAssertNotNil(center)
        XCTAssertEqual(center!.lon, 15.0, accuracy: 1e-4)
        XCTAssertEqual(center!.lat, -10.0, accuracy: 1e-4)

        let topRight = grid.coordinate(u: 1.0, v: 1.0)
        XCTAssertNotNil(topRight)
        XCTAssertEqual(topRight!.lon, 20.0, accuracy: 1e-4)
        XCTAssertEqual(topRight!.lat, 0.0, accuracy: 1e-4)

        XCTAssertNil(grid.coordinate(u: -0.1, v: 0.5))
    }

    func testHoverGridRejectsDatelineJumpAndNaN() {
        let floats: [Float] = [
            175, 10, -175, 10,
            175, 20, -175, 20
        ]
        var data = Data()
        for val in floats {
            var le = val.bitPattern.littleEndian
            withUnsafeBytes(of: &le) { data.append(contentsOf: $0) }
        }
        let grid = HoverGrid(base64: data.base64EncodedString(), size: 2)!
        XCTAssertNil(grid.coordinate(u: 0.5, v: 0.5))

        let nanFloats: [Float] = [
            Float.nan, 0, 10, 0,
            0, 10, 10, 10
        ]
        var nanData = Data()
        for val in nanFloats {
            var le = val.bitPattern.littleEndian
            withUnsafeBytes(of: &le) { nanData.append(contentsOf: $0) }
        }
        let nanGrid = HoverGrid(base64: nanData.base64EncodedString(), size: 2)!
        XCTAssertNil(nanGrid.coordinate(u: 0.5, v: 0.5))
    }

    func testRegionHistoryStackLifecycle() {
        var stack = RegionHistoryStack()
        XCTAssertFalse(stack.isDrilledDown)

        let root = RegionEntry(label: "Full Grid", region: [0, 360, -90, 90], projection: "Q16c", projectionMode: "auto", title: "Root")
        stack.reset(root: root)
        XCTAssertFalse(stack.isDrilledDown)
        XCTAssertFalse(stack.canGoBack)
        XCTAssertFalse(stack.canGoForward)

        let sub1 = RegionEntry(label: "Pacific", region: [110, 250, -30, 50], projection: "M16c", projectionMode: "auto", title: "Pacific")
        let sub2 = RegionEntry(label: "SCS", region: [105, 125, 0, 25], projection: "M16c", projectionMode: "auto", title: "SCS")
        stack.push(sub1)
        stack.push(sub2)

        XCTAssertTrue(stack.isDrilledDown)
        XCTAssertEqual(stack.current?.label, "SCS")
        XCTAssertTrue(stack.canGoBack)
        XCTAssertFalse(stack.canGoForward)

        XCTAssertEqual(stack.goBack()?.label, "Pacific")
        XCTAssertTrue(stack.canGoForward)
        XCTAssertEqual(stack.goForward()?.label, "SCS")
        XCTAssertEqual(stack.jump(to: 0)?.label, "Full Grid")

        // Pushing after going back truncates forward branch
        let alt = RegionEntry(label: "Atlantic", region: [-70, 0, 0, 50], projection: "M16c", projectionMode: "auto", title: "Atlantic")
        stack.push(alt)
        XCTAssertEqual(stack.entries.map(\.label), ["Full Grid", "Atlantic"])
        XCTAssertFalse(stack.canGoForward)
    }

    func testPlotConfigJSONRoundTrip() throws {
        var cfg = PlotConfig()
        cfg.sourcePath = "/tmp/sample.nc"
        cfg.variableName = "temp"
        cfg.region = [100, 130, 20, 40]
        cfg.cptRange = [-5, 35]
        cfg.sliceIndices = ["time": 2, "depth": 1]
        cfg.cpt = "vik"
        cfg.borderMode = "cn_la"
        cfg.borderPen = "0.6p,red"
        cfg.cnBorderDir = "/tmp/cn"

        let data = try JSONEncoder().encode(cfg)
        let decoded = try JSONDecoder().decode(PlotConfig.self, from: data)
        XCTAssertEqual(decoded, cfg)
    }

    @MainActor
    func testDefaultDatasetOpenBehaviorIsSmart() {
        UserDefaults.standard.removeObject(forKey: "Graticule.datasetOpenBehavior")
        UserDefaults.standard.removeObject(forKey: "Graticule.enableCNBorders")
        let env = BackendEnvironment()
        XCTAssertEqual(env.datasetOpenBehavior, .smart)
        XCTAssertFalse(env.enableCNBorders)
    }

    func testLiveRPCServerIntegration() async throws {
        let python = BackendEnvironment.detectPythonPath()
        let gmt = BackendEnvironment.detectGMTPath(pythonPath: python)
        let root = BackendEnvironment.detectSourceRoot()

        try XCTSkipUnless(
            python != nil && gmt != nil && root != nil,
            "Missing runtime: python=\(python ?? "nil") gmt=\(gmt ?? "nil") root=\(root ?? "nil")"
        )

        let tempNC = FileManager.default.temporaryDirectory
            .appendingPathComponent("swift_rpc_test_\(UUID().uuidString).nc")
        defer { try? FileManager.default.removeItem(at: tempNC) }

        // Create tiny sample NetCDF via Python xarray/numpy
        let createProc = Process()
        createProc.executableURL = URL(fileURLWithPath: python!)
        createProc.arguments = [
            "-B", "-c",
            """
            import numpy as np, xarray as xr
            lon = np.linspace(100, 130, 13)
            lat = np.linspace(10, 40, 13)
            val = np.sin(np.deg2rad(lat[:, None])) * np.cos(np.deg2rad(lon[None, :]))
            xr.Dataset({'sst': (('lat', 'lon'), val, {'units': 'degC'})}, coords={'lon': lon, 'lat': lat}).to_netcdf(r'\(tempNC.path)')
            """
        ]
        try createProc.run()
        createProc.waitUntilExit()
        XCTAssertEqual(createProc.terminationStatus, 0)

        let client = RPCClient()
        await client.configure(pythonPath: python, gmtPath: gmt, sourceRoot: root)

        let info = try await client.ping()
        XCTAssertEqual(info.version, "0.7.1")
        XCTAssertFalse(info.gmtVersion.isEmpty)

        let ds = try await client.openDataset(path: tempNC.path)
        XCTAssertEqual(ds.plotableVariables.first?.name, "sst")

        let variable = ds.plotableVariables[0]
        let cfg = PlotConfig.defaultConfig(for: variable, dataset: ds, previewLOD: true, previewDPI: 90)
        let render = try await client.render(config: cfg, includeHover: true)
        XCTAssertTrue(FileManager.default.fileExists(atPath: render.imagePath))
        XCTAssertEqual(render.hoverGridSize, 65)

        let hover = HoverGrid(base64: render.hoverB64, size: render.hoverGridSize)
        XCTAssertNotNil(hover)
        let mid = hover?.coordinate(u: 0.5, v: 0.5)
        XCTAssertNotNil(mid)
        XCTAssertEqual(mid!.lon, 115.0, accuracy: 2.0)
        XCTAssertEqual(mid!.lat, 25.0, accuracy: 2.0)

        await client.shutdown()
    }

    func testProjectionCenterMeridianAndCartesianLabels() {
        XCTAssertTrue(ProjectionCenterHelper.supportsCentralMeridian("R0/16c"))
        XCTAssertTrue(ProjectionCenterHelper.supportsCentralMeridian("Q16c"))
        XCTAssertFalse(ProjectionCenterHelper.supportsCentralMeridian("X16c/10c"))
        XCTAssertFalse(ProjectionCenterHelper.supportsCentralMeridian("IntMollOcean"))

        XCTAssertEqual(ProjectionCenterHelper.extractCentralMeridian(from: "W0/16c"), 0.0)
        XCTAssertEqual(ProjectionCenterHelper.extractCentralMeridian(from: "S180/90/15c"), 180.0)
        XCTAssertNil(ProjectionCenterHelper.extractCentralMeridian(from: "Q16c"))

        XCTAssertEqual(ProjectionCenterHelper.applyingCentralMeridian(180.0, to: "R0/16c"), "R180/16c")
        XCTAssertEqual(ProjectionCenterHelper.applyingCentralMeridian(180.0, to: "Q16c"), "Q180/16c")
        XCTAssertEqual(ProjectionCenterHelper.applyingCentralMeridian(0.0, to: "Kf180/16c"), "Kf0/16c")
        XCTAssertEqual(ProjectionCenterHelper.applyingCentralMeridian(180.0, to: "S0/90/15c"), "S180/90/15c")

        let shifted = ProjectionCenterHelper.shiftedGlobalRegion([-180.0, 180.0, -90.0, 90.0], lon0: 180.0)
        XCTAssertEqual(shifted, [0.0, 360.0, -90.0, 90.0])

        XCTAssertEqual(
            RegionEntry.formatRegionLabel([0.0, 1415.0, 0.0, 959.0], isGeographic: false),
            "X 0–1415, Y 0–959"
        )
        XCTAssertTrue(GMTColorPalettes.builtInNames.contains("panoply"))
        XCTAssertTrue(GMTColorPalettes.builtInNames.contains("categorical"))
        XCTAssertFalse(GMTColorPalettes.builtInNames.contains("coolwarm"))
    }

    func testInspectTargetCDLSummaryAndDimensionlessColorbarTitle() throws {
        let json = """
        {
          "file_path": "/tmp/tid.nc",
          "file_name": "tid.nc",
          "dimensions": {"lat": 10, "lon": 20},
          "dimension_coords": {},
          "global_attrs": [["title", "Sample TID"]],
          "variables": [
            {
              "name": "tid",
              "display_title": "Type Identifier",
              "dimensions": ["lat", "lon"],
              "shape": [10, 20],
              "dtype": "int8",
              "attrs": [["units", "1"], ["long_name", "Type Identifier"]],
              "is_2d_plotable": true,
              "x_dim": "lon",
              "y_dim": "lat",
              "slice_dims": [],
              "is_geographic": true,
              "unsupported_reason": "",
              "x_range": [-180.0, 180.0],
              "y_range": [-90.0, 90.0],
              "v_range": [0.0, 70.0],
              "flag_values": [0.0, 10.0],
              "flag_meanings": ["Land", "Singlebeam"],
              "is_categorical": true,
              "default_cpt": "categorical",
              "default_symmetric": false
            }
          ]
        }
        """
        let ds = try JSONDecoder().decode(DatasetMeta.self, from: Data(json.utf8))
        let cfg = PlotConfig.defaultConfig(for: ds.variables[0], dataset: ds, previewLOD: true, previewDPI: 90)
        XCTAssertEqual(cfg.colorbarTitle, "")

        let cdl = ds.cdlSummary()
        XCTAssertTrue(cdl.contains("netcdf tid {"))
        XCTAssertTrue(cdl.contains("lat = 10 ;"))
        XCTAssertTrue(cdl.contains("int8 tid(lat, lon) ;"))
        XCTAssertTrue(cdl.contains("tid:units = \"1\" ;"))
        XCTAssertTrue(cdl.contains(":title = \"Sample TID\" ;"))

        let target = InspectTarget.variable(datasetPath: "/tmp/tid.nc", variableName: "tid")
        XCTAssertEqual(target.datasetPath, "/tmp/tid.nc")
        XCTAssertEqual(target.variableName, "tid")
    }
}
