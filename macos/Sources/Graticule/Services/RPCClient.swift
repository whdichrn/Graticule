import Darwin
import Foundation

private final class UncheckedSendableBox<T>: @unchecked Sendable {
    let value: T
    init(_ value: T) { self.value = value }
}

enum RPCError: LocalizedError, Sendable {
    case missingPython
    case missingSourceRoot
    case processNotRunning(String)
    case invalidResponse(String)
    case serverError(String)

    var errorDescription: String? {
        switch self {
        case .missingPython:
            return "Python runtime was not found. Configure Python in Settings (⌘,)."
        case .missingSourceRoot:
            return "graticule Python source directory was not found. Configure Source Root in Settings (⌘,)."
        case .processNotRunning(let detail):
            return "Backend process stopped: \(detail)"
        case .invalidResponse(let detail):
            return "Invalid backend response: \(detail)"
        case .serverError(let detail):
            return detail
        }
    }
}

private struct RPCEnvelope: Decodable {
    let id: Int?
    let ok: Bool
    let result: AnyDecodable?
    let error: String?
}

private struct AnyDecodable: Decodable {
    let rawData: Data

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        let value = try Self.decodeValue(from: container)
        self.rawData = try JSONSerialization.data(withJSONObject: value, options: [])
    }

    private static func decodeValue(from container: SingleValueDecodingContainer) throws -> Any {
        if container.decodeNil() {
            return NSNull()
        }
        if let boolVal = try? container.decode(Bool.self) {
            return boolVal
        }
        if let intVal = try? container.decode(Int.self) {
            return intVal
        }
        if let doubleVal = try? container.decode(Double.self) {
            return doubleVal
        }
        if let strVal = try? container.decode(String.self) {
            return strVal
        }
        if let arrVal = try? container.decode([AnyDecodableValue].self) {
            return arrVal.map(\.value)
        }
        if let dictVal = try? container.decode([String: AnyDecodableValue].self) {
            return dictVal.mapValues(\.value)
        }
        return NSNull()
    }
}

private struct AnyDecodableValue: Decodable {
    let value: Any

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if container.decodeNil() {
            value = NSNull()
        } else if let b = try? container.decode(Bool.self) {
            value = b
        } else if let i = try? container.decode(Int.self) {
            value = i
        } else if let d = try? container.decode(Double.self) {
            value = d
        } else if let s = try? container.decode(String.self) {
            value = s
        } else if let arr = try? container.decode([AnyDecodableValue].self) {
            value = arr.map(\.value)
        } else if let dict = try? container.decode([String: AnyDecodableValue].self) {
            value = dict.mapValues(\.value)
        } else {
            value = NSNull()
        }
    }
}

actor RPCClient {
    private var process: Process?
    private var stdinPipe: Pipe?
    private let terminationLock = NSLock()
    private nonisolated(unsafe) var liveProcess: Process?
    private nonisolated(unsafe) var liveStdinPipe: Pipe?
    private var stdoutTask: Task<Void, Never>?
    private var stderrTask: Task<Void, Never>?
    private var nextID: Int = 1
    private var waiters: [Int: CheckedContinuation<Data, Error>] = [:]
    private var stderrBuffer: [String] = []
    private var launchConfig: (python: String, gmt: String?, root: String)?

    nonisolated func terminateImmediately() {
        terminationLock.lock()
        let proc = liveProcess
        let pipe = liveStdinPipe
        liveProcess = nil
        liveStdinPipe = nil
        terminationLock.unlock()

        try? pipe?.fileHandleForWriting.close()
        if let proc, proc.isRunning {
            proc.terminate()
        }
    }

    private func setLiveHandles(process: Process?, stdinPipe: Pipe?) {
        terminationLock.lock()
        liveProcess = process
        liveStdinPipe = stdinPipe
        terminationLock.unlock()
    }

    func configure(pythonPath: String?, gmtPath: String?, sourceRoot: String?) {
        guard let pythonPath, let sourceRoot else {
            launchConfig = nil
            return
        }
        launchConfig = (pythonPath, gmtPath, sourceRoot)
    }

    func restart(pythonPath: String?, gmtPath: String?, sourceRoot: String?) async {
        await shutdown()
        configure(pythonPath: pythonPath, gmtPath: gmtPath, sourceRoot: sourceRoot)
    }

    private func ensureStarted() throws {
        if let process, process.isRunning {
            return
        }
        guard let cfg = launchConfig else {
            if BackendEnvironment.detectPythonPath() == nil {
                throw RPCError.missingPython
            }
            throw RPCError.missingSourceRoot
        }

        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: cfg.python)
        proc.arguments = ["-B", "-m", "graticule.backend.rpc_server"]
        proc.currentDirectoryURL = URL(fileURLWithPath: cfg.root)

        var env = ProcessInfo.processInfo.environment
        let existingPyPath = env["PYTHONPATH"]
        env["PYTHONPATH"] = existingPyPath.map { "\(cfg.root):\($0)" } ?? cfg.root
        if let gmt = cfg.gmt {
            env["GMT_BIN"] = gmt
            let gmtDir = URL(fileURLWithPath: gmt).deletingLastPathComponent().path
            env["PATH"] = "\(gmtDir):\(env["PATH"] ?? "/usr/bin:/bin")"
        }
        env["PYTHONUNBUFFERED"] = "1"
        proc.environment = env

        let inPipe = Pipe()
        let outPipe = Pipe()
        let errPipe = Pipe()
        proc.standardInput = inPipe
        proc.standardOutput = outPipe
        proc.standardError = errPipe

        stderrBuffer.removeAll()

        proc.terminationHandler = { [weak self] terminated in
            let status = terminated.terminationStatus
            Task {
                await self?.handleTermination(status: status)
            }
        }

        try proc.run()
        self.process = proc
        self.stdinPipe = inPipe
        setLiveHandles(process: proc, stdinPipe: inPipe)

        let outStream = Self.makeLineStream(from: outPipe.fileHandleForReading, label: "io.graticule.rpc.stdout")
        stdoutTask = Task.detached(priority: .userInitiated) { [weak self] in
            for await line in outStream {
                await self?.handleLine(line)
            }
            await self?.handleEOF()
        }

        let errStream = Self.makeLineStream(from: errPipe.fileHandleForReading, label: "io.graticule.rpc.stderr")
        stderrTask = Task.detached(priority: .utility) { [weak self] in
            for await line in errStream {
                await self?.appendStderr(line)
            }
        }
    }

    private nonisolated static func makeLineStream(from handle: FileHandle, label: String) -> AsyncStream<String> {
        let (stream, continuation) = AsyncStream<String>.makeStream()
        let box = UncheckedSendableBox(handle)
        DispatchQueue(label: label).async {
            let fileHandle = box.value
            let fd = fileHandle.fileDescriptor
            var buffer = [UInt8](repeating: 0, count: 8192)
            var pending = Data()

            while true {
                let n = Darwin.read(fd, &buffer, buffer.count)
                if n > 0 {
                    pending.append(contentsOf: buffer[0..<n])
                    while let nl = pending.firstIndex(of: 0x0A) {
                        var lineSlice = pending[pending.startIndex..<nl]
                        if lineSlice.last == 0x0D {
                            lineSlice = lineSlice.dropLast()
                        }
                        continuation.yield(String(decoding: lineSlice, as: UTF8.self))
                        pending.removeSubrange(pending.startIndex...nl)
                    }
                } else if n == 0 {
                    if !pending.isEmpty {
                        continuation.yield(String(decoding: pending, as: UTF8.self))
                    }
                    break
                } else {
                    if errno == EINTR {
                        continue
                    }
                    break
                }
            }
            continuation.finish()
        }
        return stream
    }

    private func appendStderr(_ line: String) {
        stderrBuffer.append(line)
        if stderrBuffer.count > 80 {
            stderrBuffer.removeFirst(stderrBuffer.count - 80)
        }
    }

    private func handleLine(_ line: String) {
        guard let data = line.data(using: .utf8) else { return }
        guard let jsonObject = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let id = jsonObject["id"] as? Int else {
            return
        }
        guard let waiter = waiters.removeValue(forKey: id) else { return }
        let ok = (jsonObject["ok"] as? Bool) ?? false
        if ok {
            let resultObj = jsonObject["result"] ?? [String: Any]()
            do {
                let resultData = try JSONSerialization.data(withJSONObject: resultObj, options: [])
                waiter.resume(returning: resultData)
            } catch {
                waiter.resume(throwing: RPCError.invalidResponse(error.localizedDescription))
            }
        } else {
            let message = (jsonObject["error"] as? String) ?? "Unknown backend error"
            waiter.resume(throwing: RPCError.serverError(message))
        }
    }

    private func handleEOF() {
        failPending(reason: stderrSummary())
    }

    private func handleTermination(status: Int32) {
        process = nil
        stdinPipe = nil
        setLiveHandles(process: nil, stdinPipe: nil)
        failPending(reason: "exit code \(status). \(stderrSummary())")
    }

    private func stderrSummary() -> String {
        let tail = stderrBuffer.suffix(8).joined(separator: "\n")
        return tail.isEmpty ? "Check Python/GMT configuration in Settings." : tail
    }

    private func failPending(reason: String) {
        let pending = waiters
        waiters.removeAll()
        for (_, waiter) in pending {
            waiter.resume(throwing: RPCError.processNotRunning(reason))
        }
    }

    private func callRaw(method: String, params: [String: Any] = [:]) async throws -> Data {
        try ensureStarted()
        guard let pipe = stdinPipe else {
            throw RPCError.processNotRunning("stdin closed")
        }
        let reqID = nextID
        nextID += 1

        let payload: [String: Any] = [
            "id": reqID,
            "method": method,
            "params": params
        ]
        var lineData = try JSONSerialization.data(withJSONObject: payload, options: [])
        lineData.append(0x0A)

        return try await withCheckedThrowingContinuation { continuation in
            waiters[reqID] = continuation
            do {
                try pipe.fileHandleForWriting.write(contentsOf: lineData)
            } catch {
                if let removed = waiters.removeValue(forKey: reqID) {
                    removed.resume(throwing: RPCError.processNotRunning(error.localizedDescription))
                }
            }
        }
    }

    private func call<Response: Decodable>(
        method: String,
        params: [String: Any] = [:],
        as type: Response.Type = Response.self
    ) async throws -> Response {
        let data = try await callRaw(method: method, params: params)
        do {
            return try JSONDecoder().decode(Response.self, from: data)
        } catch {
            throw RPCError.invalidResponse("\(method): \(error.localizedDescription)")
        }
    }

    private static func encodeToDict<T: Encodable>(_ value: T) throws -> [String: Any] {
        let data = try JSONEncoder().encode(value)
        guard let dict = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw RPCError.invalidResponse("Failed to serialize request payload")
        }
        return dict
    }

    func ping() async throws -> ServerInfo {
        try await call(method: "ping")
    }

    func openDataset(path: String) async throws -> DatasetMeta {
        try await call(method: "open_dataset", params: ["path": path])
    }

    func recommendProjections(
        region: [Double]?,
        varName: String,
        varAttrs: [String: String],
        isGeographic: Bool
    ) async throws -> [ProjectionOption] {
        struct Wrapper: Decodable {
            let projections: [ProjectionOption]
        }
        var params: [String: Any] = [
            "var_name": varName,
            "var_attrs": varAttrs,
            "is_geographic": isGeographic
        ]
        if let region {
            params["region"] = region
        }
        let wrapped: Wrapper = try await call(method: "recommend_projections", params: params)
        return wrapped.projections
    }

    func render(
        config: PlotConfig,
        outputPath: String? = nil,
        isExport: Bool = false,
        includeHover: Bool = true
    ) async throws -> RenderResult {
        var params: [String: Any] = [
            "config": try Self.encodeToDict(config),
            "is_export": isExport,
            "include_hover": includeHover
        ]
        if let outputPath {
            params["output_path"] = outputPath
        }
        return try await call(method: "render", params: params)
    }

    func scanRange(
        sourcePath: String,
        variableName: String,
        sliceIndices: [String: Int],
        region: [Double]?,
        maskMode: String,
        symmetric: Bool
    ) async throws -> RangeResult {
        var params: [String: Any] = [
            "source_path": sourcePath,
            "variable_name": variableName,
            "slice_indices": sliceIndices,
            "mask_mode": maskMode,
            "symmetric": symmetric
        ]
        if let region {
            params["region"] = region
        }
        return try await call(method: "scan_range", params: params)
    }

    func selectionRegion(
        u0: Double,
        v0: Double,
        u1: Double,
        v1: Double,
        region: [Double],
        projection: String,
        dimsCm: [Double],
        gmtConf: String = ""
    ) async throws -> [Double]? {
        struct Wrapper: Decodable {
            let region: [Double]?
        }
        let wrapped: Wrapper = try await call(
            method: "selection_region",
            params: [
                "u0": u0,
                "v0": v0,
                "u1": u1,
                "v1": v1,
                "region": region,
                "projection": projection,
                "dims_cm": dimsCm,
                "gmt_conf": gmtConf
            ]
        )
        return wrapped.region
    }

    func generateScript(config: PlotConfig, outputFilename: String = "output.png") async throws -> String {
        struct Wrapper: Decodable {
            let script: String
        }
        let wrapped: Wrapper = try await call(
            method: "generate_script",
            params: [
                "config": try Self.encodeToDict(config),
                "output_filename": outputFilename
            ]
        )
        return wrapped.script
    }

    func parseScript(_ script: String, fallback: PlotConfig) async throws -> PlotConfig {
        struct Wrapper: Decodable {
            let config: PlotConfig
        }
        let wrapped: Wrapper = try await call(
            method: "parse_script",
            params: [
                "script": script,
                "fallback_config": try Self.encodeToDict(fallback)
            ]
        )
        return wrapped.config
    }

    func runScript(_ script: String, fallback: PlotConfig) async throws -> ScriptRunResult {
        try await call(
            method: "run_script",
            params: [
                "script": script,
                "fallback_config": try Self.encodeToDict(fallback)
            ]
        )
    }

    func cnBorderStatus(explicitDir: String = "") async throws -> CNBorderStatus {
        try await call(method: "cn_border_status", params: ["cn_border_dir": explicitDir])
    }

    func installCNBorder(destDir: String? = nil, zipPath: String? = nil) async throws -> CNBorderStatus {
        var params: [String: Any] = [:]
        if let destDir, !destDir.isEmpty {
            params["dest_dir"] = destDir
        }
        if let zipPath, !zipPath.isEmpty {
            params["zip_path"] = zipPath
        }
        return try await call(method: "install_cn_border", params: params)
    }

    func shutdown() async {
        guard let proc = process, proc.isRunning else {
            stdoutTask?.cancel()
            stderrTask?.cancel()
            process = nil
            stdinPipe = nil
            setLiveHandles(process: nil, stdinPipe: nil)
            return
        }
        _ = try? await callRaw(method: "shutdown")
        try? stdinPipe?.fileHandleForWriting.close()
        for _ in 0..<4 where proc.isRunning {
            try? await Task.sleep(for: .milliseconds(40))
        }
        if proc.isRunning {
            proc.terminate()
        }
        stdoutTask?.cancel()
        stderrTask?.cancel()
        process = nil
        stdinPipe = nil
        setLiveHandles(process: nil, stdinPipe: nil)
        failPending(reason: "Backend shutdown")
    }
}
