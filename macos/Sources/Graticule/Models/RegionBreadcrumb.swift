import Foundation

struct RegionEntry: Identifiable, Sendable, Equatable {
    let id: UUID
    let label: String
    let region: [Double]?
    let projection: String
    let projectionMode: String
    let title: String
    var cachedRender: RenderResult?
    var cacheStyleSignature: String?

    init(
        id: UUID = UUID(),
        label: String,
        region: [Double]?,
        projection: String,
        projectionMode: String,
        title: String,
        cachedRender: RenderResult? = nil,
        cacheStyleSignature: String? = nil
    ) {
        self.id = id
        self.label = label
        self.region = region
        self.projection = projection
        self.projectionMode = projectionMode
        self.title = title
        self.cachedRender = cachedRender
        self.cacheStyleSignature = cacheStyleSignature
    }

    static func formatRegionLabel(_ region: [Double], isGeographic: Bool = true) -> String {
        guard region.count == 4 else { return "Region" }
        if isGeographic {
            return String(format: "%.1f°–%.1f°, %.1f°–%.1f°", region[0], region[1], region[2], region[3])
        }
        return String(format: "X %.4g–%.4g, Y %.4g–%.4g", region[0], region[1], region[2], region[3])
    }
}

struct RegionHistoryStack: Sendable, Equatable {
    private(set) var entries: [RegionEntry] = []
    private(set) var currentIndex: Int = 0

    var isDrilledDown: Bool { entries.count > 1 }
    var current: RegionEntry? {
        guard entries.indices.contains(currentIndex) else { return nil }
        return entries[currentIndex]
    }
    var canGoBack: Bool { currentIndex > 0 }
    var canGoForward: Bool { currentIndex + 1 < entries.count }

    mutating func reset(root: RegionEntry) {
        entries = [root]
        currentIndex = 0
    }

    mutating func push(_ entry: RegionEntry) {
        if entries.isEmpty {
            entries = [entry]
            currentIndex = 0
            return
        }
        if currentIndex + 1 < entries.count {
            entries.removeSubrange((currentIndex + 1)..<entries.count)
        }
        entries.append(entry)
        currentIndex = entries.count - 1
    }

    @discardableResult
    mutating func goBack() -> RegionEntry? {
        guard canGoBack else { return nil }
        currentIndex -= 1
        return entries[currentIndex]
    }

    @discardableResult
    mutating func goForward() -> RegionEntry? {
        guard canGoForward else { return nil }
        currentIndex += 1
        return entries[currentIndex]
    }

    @discardableResult
    mutating func jump(to index: Int) -> RegionEntry? {
        guard entries.indices.contains(index) else { return nil }
        currentIndex = index
        return entries[currentIndex]
    }

    mutating func updateCurrentRender(_ render: RenderResult, styleSignature: String) {
        guard entries.indices.contains(currentIndex) else { return }
        entries[currentIndex].cachedRender = render
        entries[currentIndex].cacheStyleSignature = styleSignature
    }

    mutating func clearCachedRenders() {
        for idx in entries.indices {
            entries[idx].cachedRender = nil
            entries[idx].cacheStyleSignature = nil
        }
    }
}
