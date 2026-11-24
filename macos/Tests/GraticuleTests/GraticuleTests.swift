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
        XCTAssertEqual(info.version, "0.4.0")
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
}
