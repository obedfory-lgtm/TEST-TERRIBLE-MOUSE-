import SwiftUI
import UniformTypeIdentifiers

private enum WorkspaceSection: String, CaseIterable, Identifiable, Hashable {
    case dashboard = "Home"
    case scanner = "Scan"
    case memory = "Memory"
    case results = "Results"
    case files = "Files"

    var id: String { rawValue }
    var symbol: String {
        switch self {
        case .dashboard: "waveform.path.ecg"
        case .scanner: "scope"
        case .memory: "memorychip"
        case .results: "list.bullet.rectangle"
        case .files: "doc.zipper"
        }
    }
}

private enum StudioPalette {
    static let background = Color(red: 0.055, green: 0.065, blue: 0.075)
    static let surface = Color(red: 0.105, green: 0.12, blue: 0.13)
    static let line = Color.white.opacity(0.10)
    static let lime = Color(red: 0.76, green: 0.94, blue: 0.24)
    static let cyan = Color(red: 0.30, green: 0.82, blue: 0.88)
    static let amber = Color(red: 1.0, green: 0.68, blue: 0.30)
}

public struct DiagnosticWorkspaceView: View {
    @State private var registry: MemoryRegionRegistry
    @State private var scanner = MemoryScanner()
    @State private var snapshotStore = SnapshotStore()
    @State private var monitor = LiveValueMonitor()
    @State private var regions: [MemoryRegionInfo] = []
    @State private var results: [ScanResult] = []
    @State private var snapshots: [MemorySnapshot] = []
    @State private var hasScanSession = false
    @State private var section: WorkspaceSection = .dashboard
    @State private var isOverlayExpanded = false
    @State private var watchedIDs = Set<String>()
    @State private var errorText: String?

    public init(registry: MemoryRegionRegistry = MemoryRegionRegistry()) {
        _registry = State(initialValue: registry)
    }

    public var body: some View {
        ZStack(alignment: .bottomTrailing) {
            TabView(selection: $section) {
                DashboardScreen(regions: regions, resultCount: results.count, registry: registry, errorText: $errorText)
                    .tabItem { Label("Home", systemImage: WorkspaceSection.dashboard.symbol) }
                    .tag(WorkspaceSection.dashboard)
                ScannerScreen(registry: registry, scanner: scanner, results: $results, hasSession: $hasScanSession, errorText: $errorText)
                    .tabItem { Label("Scan", systemImage: WorkspaceSection.scanner.symbol) }
                    .tag(WorkspaceSection.scanner)
                MemoryMapScreen(regions: regions, registry: registry)
                    .tabItem { Label("Memory", systemImage: WorkspaceSection.memory.symbol) }
                    .tag(WorkspaceSection.memory)
                ResultsScreen(results: results, watchedIDs: $watchedIDs)
                    .tabItem { Label("Results", systemImage: WorkspaceSection.results.symbol) }
                    .tag(WorkspaceSection.results)
                FilesScreen(results: $results, registry: registry, scanner: scanner, snapshotStore: snapshotStore, monitor: monitor, snapshots: $snapshots, hasSession: $hasScanSession, errorText: $errorText)
                    .tabItem { Label("Files", systemImage: WorkspaceSection.files.symbol) }
                    .tag(WorkspaceSection.files)
            }
            .tint(StudioPalette.lime)
            .safeAreaInset(edge: .top, spacing: 0) {
                HStack(spacing: 8) {
                    Circle().fill(StudioPalette.lime).frame(width: 7, height: 7)
                    Text("MEMORY STUDIO").font(.system(size: 10, weight: .bold, design: .monospaced)).tracking(1.3)
                    Spacer()
                    Text("HOST-OWNED DATA").font(.system(size: 9, weight: .medium, design: .monospaced)).foregroundStyle(.secondary)
                }
                .padding(.horizontal, 18)
                .padding(.vertical, 9)
                .background(StudioPalette.background)
            }

            GeometryReader { geometry in
                FloatingDiagnosticOverlay(
                    expanded: $isOverlayExpanded,
                    section: $section,
                    regionCount: regions.count,
                    resultCount: results.count,
                    availableSize: geometry.size
                )
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomTrailing)
                .padding(.trailing, 12)
                .padding(.bottom, 74)
            }
        }
        .background(StudioPalette.background.ignoresSafeArea())
        .preferredColorScheme(.dark)
        .task {
            do {
                try await snapshotStore.restore()
                await refresh()
            } catch {
                errorText = error.localizedDescription
            }
        }
        .task(id: section) {
            while !Task.isCancelled {
                await refresh()
                try? await Task.sleep(for: .seconds(2))
            }
        }
        .alert("Diagnostic error", isPresented: Binding(
            get: { errorText != nil },
            set: { if !$0 { errorText = nil } }
        )) {
            Button("Dismiss", role: .cancel) { errorText = nil }
        } message: { Text(errorText ?? "") }
    }

    @MainActor
    private func refresh() async {
        regions = await registry.regions()
        snapshots = await snapshotStore.list()
    }
}

private struct DashboardScreen: View {
    let regions: [MemoryRegionInfo]
    let resultCount: Int
    let registry: MemoryRegionRegistry
    @Binding var errorText: String?

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    VStack(alignment: .leading, spacing: 5) {
                        Text("Recovery workspace").font(.system(size: 27, weight: .bold, design: .rounded))
                        Text("Explicitly registered buffers. Read-only unless the host grants write access.")
                            .font(.subheadline).foregroundStyle(.secondary)
                    }
                    HStack(spacing: 10) {
                        TelemetryTile(label: "REGIONS", value: "\(regions.count)", symbol: "memorychip", accent: StudioPalette.cyan)
                        TelemetryTile(label: "CANDIDATES", value: "\(resultCount)", symbol: "scope", accent: StudioPalette.lime)
                    }
                    HStack(spacing: 10) {
                        Image(systemName: "checkmark.shield.fill").foregroundStyle(StudioPalette.lime)
                        VStack(alignment: .leading, spacing: 3) {
                            Text("Registration boundary active").font(.subheadline.weight(.semibold))
                            Text("No process attachment or arbitrary address reads.").font(.caption).foregroundStyle(.secondary)
                        }
                    }
                    .padding(14)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(StudioPalette.surface, in: RoundedRectangle(cornerRadius: 12))
                    HStack {
                        VStack(alignment: .leading, spacing: 4) {
                            Text("HOST SAMPLE").font(.caption2.monospaced().weight(.bold)).foregroundStyle(StudioPalette.amber)
                            Text("Increment owned Int32 buffer").font(.subheadline)
                        }
                        Spacer()
                        Button {
                            Task {
                                do {
                                    let regions = await registry.regions()
                                    guard let region = regions.first(where: { $0.name == "host-owned-values" }) else { return }
                                    let current = try await registry.read(region: region.id, range: 0..<4)
                                    let number = try MemoryDataType.int32.decode(current)
                                    guard case .signed(let value) = number else { return }
                                    try await registry.write(region: region.id, range: 0..<4, bytes: MemoryDataType.int32.encode(String(value + 1)))
                                } catch { errorText = error.localizedDescription }
                            }
                        } label: {
                            Image(systemName: "plus").font(.headline).foregroundStyle(StudioPalette.background)
                                .frame(width: 40, height: 40).background(StudioPalette.lime, in: Circle())
                        }
                        .accessibilityLabel("Increment host-owned sample value")
                    }
                    .padding(14)
                    .background(StudioPalette.surface, in: RoundedRectangle(cornerRadius: 12))
                    VStack(alignment: .leading, spacing: 9) {
                        SectionEyebrow(title: "REGISTERED REGIONS", count: regions.count)
                        ForEach(regions) { region in
                            HStack(spacing: 10) {
                                RoundedRectangle(cornerRadius: 2).fill(region.isWritable ? StudioPalette.amber : StudioPalette.cyan)
                                    .frame(width: 3, height: 34)
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(region.name).font(.subheadline.weight(.medium))
                                    Text("\(region.byteCount.formatted()) B · \(region.isWritable ? "host writable" : "read only")")
                                        .font(.caption.monospaced()).foregroundStyle(.secondary)
                                }
                                Spacer()
                                Image(systemName: region.isWritable ? "pencil" : "lock.fill").font(.caption).foregroundStyle(.secondary)
                            }
                            .padding(10)
                            .background(StudioPalette.surface.opacity(0.72), in: RoundedRectangle(cornerRadius: 9))
                        }
                    }
                }
                .padding(16)
            }
            .background(StudioPalette.background)
            .navigationTitle("Overview")
            .toolbar { ToolbarItem(placement: .navigationBarTrailing) { Text("LIVE").font(.caption2.monospaced().bold()).foregroundStyle(StudioPalette.lime) } }
        }
    }
}

private struct TelemetryTile: View {
    let label: String
    let value: String
    let symbol: String
    let accent: Color

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Image(systemName: symbol).foregroundStyle(accent)
            Text(value).font(.system(size: 30, weight: .semibold, design: .rounded).monospacedDigit())
            Text(label).font(.system(size: 9, weight: .bold, design: .monospaced)).foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(14)
        .background(StudioPalette.surface, in: RoundedRectangle(cornerRadius: 12))
        .overlay(alignment: .top) { Rectangle().fill(accent.opacity(0.7)).frame(height: 1) }
        .clipShape(RoundedRectangle(cornerRadius: 12))
    }
}

private struct ScannerScreen: View {
    let registry: MemoryRegionRegistry
    let scanner: MemoryScanner
    @Binding var results: [ScanResult]
    @Binding var hasSession: Bool
    @Binding var errorText: String?
    @State private var dataMode = "Number"
    @State private var type: MemoryDataType = .int32
    @State private var firstMode = "Exact"
    @State private var nextMode = "Changed"
    @State private var stringEncoding: MemoryDataType = .utf8
    @State private var stringMode: StringMatchMode = .exact
    @State private var caseSensitive = true
    @State private var input = ""
    @State private var upper = ""
    @State private var pattern = ""
    @State private var textLength = "5"
    @State private var tolerance = "0"
    @State private var byteOrder: ByteOrder = .littleEndian
    @State private var alignment = false
    @State private var isScanning = false
    @State private var activeTask: Task<Void, Never>?
    @State private var progress: ScanProgress?
    @State private var startedAt: Date?
    @State private var duration: TimeInterval?
    @State private var isTruncated = false

    private let firstModes = ["Exact", "Greater", "Less", "Between", "Unknown"]
    private let nextModes = ["Changed", "Unchanged", "Increased", "Decreased", "Increased by", "Decreased by", "Same as initial", "Exact", "Greater", "Less", "Between"]

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    SectionEyebrow(title: hasSession ? "REFINE CANDIDATES" : "NEW SCAN", count: results.count)
                    Picker("Search mode", selection: $dataMode) {
                        Text("Number").tag("Number")
                        Text("Text").tag("Text")
                        Text("Bytes").tag("Bytes")
                    }
                    .pickerStyle(.segmented)
                    if dataMode == "Number" {
                        Picker("Type", selection: $type) {
                            ForEach(MemoryDataType.allCases.filter(\.isNumeric)) { Text($0.displayName).tag($0) }
                        }
                        .pickerStyle(.menu)
                        .disabled(hasSession)
                        HStack {
                            Picker("Endian", selection: $byteOrder) {
                                Text("Little").tag(ByteOrder.littleEndian)
                                Text("Big").tag(ByteOrder.bigEndian)
                            }.pickerStyle(.segmented)
                            Toggle("Byte step", isOn: $alignment).labelsHidden().accessibilityLabel("Scan every byte")
                        }
                        if type == .float32 || type == .float64 {
                            TextField("Precision tolerance", text: $tolerance).keyboardType(.decimalPad).textFieldStyle(.roundedBorder)
                        }
                    }
                    if dataMode == "Bytes" {
                        TextField("AA BB ?? 4F", text: $pattern).textInputAutocapitalization(.characters)
                            .font(.system(.body, design: .monospaced)).textFieldStyle(.roundedBorder)
                    } else if dataMode == "Text" {
                        TextField("Text to match", text: $input).textFieldStyle(.roundedBorder)
                        Picker("Encoding", selection: $stringEncoding) {
                            Text("UTF-8").tag(MemoryDataType.utf8)
                            Text("UTF-16").tag(MemoryDataType.utf16)
                            Text("ASCII").tag(MemoryDataType.ascii)
                        }
                        .pickerStyle(.menu)
                        Picker("Match", selection: $stringMode) {
                            ForEach(StringMatchMode.allCases) { Text($0.rawValue.capitalized).tag($0) }
                        }
                        .pickerStyle(.segmented)
                        Toggle("Case sensitive", isOn: $caseSensitive)
                        HStack {
                            Text("Window bytes").font(.caption).foregroundStyle(.secondary)
                            TextField("Length", text: $textLength).keyboardType(.numberPad).textFieldStyle(.roundedBorder).frame(width: 90)
                        }
                    } else {
                        Picker(hasSession ? "Refine" : "Find", selection: hasSession ? $nextMode : $firstMode) {
                            ForEach(hasSession ? nextModes : firstModes, id: \.self) { Text($0).tag($0) }
                        }
                        .pickerStyle(.menu)
                        let mode = hasSession ? nextMode : firstMode
                        if mode != "Unknown" {
                            TextField(mode == "Between" ? "Lower bound" : "Value", text: $input)
                                .keyboardType(.numbersAndPunctuation).textFieldStyle(.roundedBorder)
                        }
                        if mode == "Between" {
                            TextField("Upper bound", text: $upper).keyboardType(.numbersAndPunctuation).textFieldStyle(.roundedBorder)
                        }
                    }
                    HStack(spacing: 10) {
                        Button {
                            if isScanning { activeTask?.cancel() }
                            else { activeTask = Task { await executeScan() } }
                        } label: {
                            Label(isScanning ? "Cancel" : (hasSession ? "Next scan" : "Start scan"), systemImage: isScanning ? "stop.fill" : "play.fill")
                                .frame(maxWidth: .infinity).frame(height: 46)
                        }
                        .buttonStyle(.borderedProminent).tint(isScanning ? .red : StudioPalette.lime)
                        .disabled(!isScanning && dataMode != "Number" && input.isEmpty && dataMode == "Text")
                        if hasSession {
                            Button {
                                activeTask?.cancel()
                                Task { await scanner.clear(); results = []; hasSession = false; progress = nil; duration = nil }
                            } label: { Image(systemName: "arrow.counterclockwise").frame(width: 46, height: 46) }
                                .buttonStyle(.bordered).accessibilityLabel("Reset scan")
                        }
                    }
                    if isScanning, let progress, progress.total > 0 {
                        ProgressView(value: Double(progress.processed), total: Double(progress.total)).tint(StudioPalette.lime)
                        Text("\(progress.processed.formatted()) / \(progress.total.formatted()) positions · \(progress.matches.formatted()) matches")
                            .font(.caption.monospaced()).foregroundStyle(.secondary)
                    } else if isScanning { ProgressView().tint(StudioPalette.lime) }
                    if let duration {
                        Text("Completed in \(duration.formatted(.number.precision(.fractionLength(2)))) s")
                            .font(.caption.monospaced()).foregroundStyle(.secondary)
                    }
                    if isTruncated { Label("Result cap reached. Narrow the scan.", systemImage: "exclamationmark.triangle.fill").font(.caption).foregroundStyle(StudioPalette.amber) }
                    VStack(alignment: .leading, spacing: 8) {
                        SectionEyebrow(title: "LATEST MATCHES", count: results.count)
                        ForEach(results.prefix(6)) { result in
                            HStack {
                                Text(String(format: "+0x%X", result.offset)).font(.caption.monospaced()).foregroundStyle(.secondary)
                                Spacer()
                                Text(result.currentValue?.description ?? "-").font(.subheadline.monospaced().weight(.semibold))
                                Text(result.dataType.displayName).font(.caption2).foregroundStyle(StudioPalette.cyan)
                            }
                            .padding(.vertical, 7)
                            .overlay(alignment: .bottom) { Rectangle().fill(StudioPalette.line).frame(height: 1) }
                        }
                    }
                }
                .padding(16)
            }
            .background(StudioPalette.background)
            .navigationTitle("Scanner")
            .onChange(of: dataMode) { _ in
                activeTask?.cancel()
                Task { await scanner.clear(); results = []; hasSession = false }
            }
        }
    }

    @MainActor
    private func executeScan() async {
        isScanning = true
        startedAt = Date()
        progress = nil
        isTruncated = false
        defer { isScanning = false; activeTask = nil; duration = startedAt.map { Date().timeIntervalSince($0) } }
        do {
            let regions = await registry.snapshots()
            guard !regions.isEmpty else { throw MemoryEngineError.invalidValue("register an owned buffer before scanning") }
            if dataMode == "Bytes" {
                results = try await scanner.scanBytes(
                    regions: regions,
                    pattern: BytePattern.parse(pattern),
                    progress: { update in Task { @MainActor in progress = update } }
                )
            } else if dataMode == "Text" {
                guard let length = Int(textLength), length > 0 else { throw MemoryEngineError.invalidValue(textLength) }
                results = try await scanner.scanStrings(
                    regions: regions,
                    target: input,
                    encoding: stringEncoding,
                    byteLength: length,
                    byteOrder: byteOrder,
                    mode: stringMode,
                    caseSensitive: caseSensitive
                )
            } else {
                guard let toleranceValue = Double(tolerance), toleranceValue >= 0 else { throw MemoryEngineError.invalidValue(tolerance) }
                await scanner.setTolerance(toleranceValue)
                if hasSession {
                    results = try await scanner.nextScan(
                        regions: regions,
                        criterion: makeNextCriterion(),
                        byteOrder: byteOrder,
                        progress: { update in Task { @MainActor in progress = update } }
                    )
                } else {
                    results = try await scanner.firstScan(
                        regions: regions,
                        type: type,
                        criterion: makeFirstCriterion(),
                        byteOrder: byteOrder,
                        alignment: alignment ? .everyByte : .natural,
                        progress: { update in Task { @MainActor in progress = update } }
                    )
                    hasSession = true
                }
            }
            isTruncated = await scanner.didTruncate()
        } catch is CancellationError {
            errorText = "Scan cancelled. Existing candidates are retained."
        } catch { errorText = error.localizedDescription }
    }

    private func makeFirstCriterion() -> FirstScanCriterion {
        switch firstMode {
        case "Greater": .greaterThan(input)
        case "Less": .lessThan(input)
        case "Between": .between(input, upper)
        case "Unknown": .unknown
        default: .exact(input)
        }
    }

    private func makeNextCriterion() -> NextScanCriterion {
        switch nextMode {
        case "Unchanged": .unchanged
        case "Increased": .increased
        case "Decreased": .decreased
        case "Increased by": .increasedBy(input)
        case "Decreased by": .decreasedBy(input)
        case "Same as initial": .sameAsInitial
        case "Exact": .exact(input)
        case "Greater": .greaterThan(input)
        case "Less": .lessThan(input)
        case "Between": .between(input, upper)
        default: .changed
        }
    }
}

private struct MemoryMapScreen: View {
    let regions: [MemoryRegionInfo]
    let registry: MemoryRegionRegistry
    @State private var query = ""

    private var filtered: [MemoryRegionInfo] {
        query.isEmpty ? regions : regions.filter { $0.name.localizedCaseInsensitiveContains(query) }
    }

    var body: some View {
        NavigationStack {
            List(filtered) { region in
                NavigationLink {
                    RegionInspectionScreen(region: region, registry: registry)
                } label: {
                    HStack(spacing: 11) {
                        RoundedRectangle(cornerRadius: 2).fill(region.isWritable ? StudioPalette.amber : StudioPalette.cyan).frame(width: 3, height: 40)
                        VStack(alignment: .leading, spacing: 3) {
                            Text(region.name).font(.subheadline.weight(.semibold))
                            Text("\(region.byteCount.formatted()) bytes · +\(region.isWritable ? "RW" : "RO") · \(region.dataType?.displayName ?? "raw")")
                                .font(.caption.monospaced()).foregroundStyle(.secondary)
                        }
                        Spacer()
                        Image(systemName: "chevron.right").font(.caption2).foregroundStyle(.tertiary)
                    }
                    .listRowBackground(StudioPalette.surface)
                }
            }
            .scrollContentBackground(.hidden)
            .background(StudioPalette.background)
            .searchable(text: $query, prompt: "Filter registered regions")
            .navigationTitle("Memory map")
            .overlay {
                if filtered.isEmpty { Text("No registered regions").foregroundStyle(.secondary) }
            }
        }
    }
}

private struct RegionInspectionScreen: View {
    let region: MemoryRegionInfo
    let registry: MemoryRegionRegistry
    @State private var bytes = Data()
    @State private var selectedByte: Int?
    @State private var errorText: String?
    @State private var hexSearch = ""
    @State private var searchResult: Int?
    @State private var interpretationType: MemoryDataType = .uint8
    @State private var interpretationByteOrder: ByteOrder = .littleEndian
    private let pageSize = 2_048

    var body: some View {
        List {
            Section("Registered source") {
                LabeledContent("Identifier", value: region.id.uuidString)
                LabeledContent("Size", value: "\(region.byteCount.formatted()) bytes")
                LabeledContent("Permissions", value: region.isWritable ? "Host writable" : "Read only")
            }
            Section("Hex search") {
                TextField("AA BB ?? 4F", text: $hexSearch).font(.system(.body, design: .monospaced))
                Button("Find first match") { Task { await searchBytes() } }
                    .disabled(hexSearch.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                if let searchResult {
                    LabeledContent("Match offset", value: "+0x\(String(searchResult, radix: 16).uppercased())")
                }
            }
            Section("Offset / hexadecimal / text") {
                ForEach(0..<((bytes.count + 15) / 16), id: \.self) { row in
                    let offset = row * 16
                    let chunk = bytes[offset..<min(offset + 16, bytes.count)]
                    Button { selectedByte = offset } label: {
                        VStack(alignment: .leading, spacing: 4) {
                            Text(String(format: "%08X", offset)).foregroundStyle(StudioPalette.amber)
                            Text(chunk.map { String(format: "%02X", $0) }.joined(separator: " "))
                                .foregroundStyle(.primary).lineLimit(1).minimumScaleFactor(0.7)
                            Text(String(decoding: chunk.map { (0x20...0x7E).contains($0) ? $0 : 0x2E }, as: UTF8.self))
                                .foregroundStyle(.secondary)
                        }
                        .font(.system(size: 11, weight: .medium, design: .monospaced))
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Byte offset \(offset), \(chunk.map { String(format: "%02X", $0) }.joined(separator: " "))")
                }
                if bytes.count < region.byteCount {
                    Button("Load next page") { Task { await loadPage() } }
                }
            }
            if let selectedByte, selectedByte < bytes.count {
                let byte = bytes[selectedByte]
                Section("Selected offset 0x\(String(selectedByte, radix: 16).uppercased())") {
                    LabeledContent("Unsigned", value: String(byte))
                    LabeledContent("Signed", value: String(Int8(bitPattern: byte)))
                    LabeledContent("Bits", value: String(byte, radix: 2).leftPadded(to: 8))
                    Picker("Interpret as", selection: $interpretationType) {
                        ForEach(MemoryDataType.allCases.filter(\.isNumeric)) { Text($0.displayName).tag($0) }
                    }
                    Picker("Byte order", selection: $interpretationByteOrder) {
                        Text("Little endian").tag(ByteOrder.littleEndian)
                        Text("Big endian").tag(ByteOrder.bigEndian)
                    }
                    if let width = interpretationType.width,
                       selectedByte + width <= bytes.count,
                       let value = try? interpretationType.decode(
                        bytes,
                        range: selectedByte..<(selectedByte + width),
                        byteOrder: interpretationByteOrder
                       ) {
                        LabeledContent("Typed value", value: value.description)
                    }
                }
            }
            if let errorText { Section("Read error") { Text(errorText).foregroundStyle(.red) } }
        }
        .scrollContentBackground(.hidden)
        .background(StudioPalette.background)
        .navigationTitle(region.name)
        .navigationBarTitleDisplayMode(.inline)
        .task { await loadPage() }
    }

    @MainActor
    private func loadPage() async {
        guard bytes.count < region.byteCount else { return }
        let end = min(bytes.count + pageSize, region.byteCount)
        do { bytes.append(try await registry.read(region: region.id, range: bytes.count..<end)) }
        catch { errorText = error.localizedDescription }
    }

    @MainActor
    private func searchBytes() async {
        do {
            let pattern = try BytePattern.parse(hexSearch)
            while bytes.count < region.byteCount {
                let previousCount = bytes.count
                await loadPage()
                guard bytes.count > previousCount else { throw MemoryEngineError.invalidRange }
            }
            guard let match = (0...max(0, bytes.count - pattern.bytes.count)).first(where: { pattern.matches(bytes, at: $0) }) else {
                searchResult = nil
                errorText = "No byte-pattern match in this registered region."
                return
            }
            selectedByte = match
            searchResult = match
        } catch { errorText = error.localizedDescription }
    }
}

private struct ResultsScreen: View {
    let results: [ScanResult]
    @Binding var watchedIDs: Set<String>
    @State private var query = ""
    @State private var pageSize = 250
    @State private var filterType: MemoryDataType?
    @State private var watchedOnly = false
    @State private var showFilters = false

    private var filtered: [ScanResult] {
        results.filter { result in
            (query.isEmpty || result.regionName.localizedCaseInsensitiveContains(query) || (result.currentValue?.description.localizedCaseInsensitiveContains(query) ?? false)) &&
            (filterType == nil || result.dataType == filterType) &&
            (!watchedOnly || watchedIDs.contains(result.id))
        }
    }

    var body: some View {
        NavigationStack {
            List {
                ForEach(filtered.prefix(pageSize)) { result in
                    NavigationLink {
                        ResultDetailScreen(result: result, isWatched: Binding(
                            get: { watchedIDs.contains(result.id) },
                            set: { if $0 { watchedIDs.insert(result.id) } else { watchedIDs.remove(result.id) } }
                        ))
                    } label: {
                        HStack(alignment: .center, spacing: 9) {
                            Button {
                                if watchedIDs.contains(result.id) { watchedIDs.remove(result.id) }
                                else { watchedIDs.insert(result.id) }
                            } label: {
                                Image(systemName: watchedIDs.contains(result.id) ? "star.fill" : "star")
                                    .foregroundStyle(watchedIDs.contains(result.id) ? StudioPalette.amber : .secondary)
                            }
                            .buttonStyle(.plain)
                            VStack(alignment: .leading, spacing: 3) {
                                Text(result.currentValue?.description ?? "-").font(.subheadline.monospaced().weight(.semibold))
                                Text("\(result.regionName) +0x\(String(result.offset, radix: 16).uppercased()) · \(result.dataType.displayName)")
                                    .font(.caption2.monospaced()).foregroundStyle(.secondary).lineLimit(1)
                                if let old = result.previousValue {
                                    Text("Was \(old.description)").font(.caption2).foregroundStyle(StudioPalette.cyan)
                                }
                            }
                            Spacer(minLength: 0)
                        }
                    }
                    .listRowBackground(StudioPalette.surface)
                }
                if filtered.count > pageSize {
                    Button("Load next \(min(250, filtered.count - pageSize))") { pageSize = min(filtered.count, pageSize + 250) }
                }
            }
            .scrollContentBackground(.hidden)
            .background(StudioPalette.background)
            .overlay {
                if filtered.isEmpty { Text("No candidates. Run a scan to create a result set.").foregroundStyle(.secondary).padding() }
            }
            .searchable(text: $query, prompt: "Value or region")
            .navigationTitle("Results · \(filtered.count)")
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button { showFilters = true } label: { Image(systemName: "line.3.horizontal.decrease.circle") }
                        .accessibilityLabel("Filter results")
                }
            }
            .sheet(isPresented: $showFilters) {
                NavigationStack {
                    Form {
                        Picker("Data type", selection: $filterType) {
                            Text("All types").tag(MemoryDataType?.none)
                            ForEach(MemoryDataType.allCases) { Text($0.displayName).tag(Optional($0)) }
                        }
                        Toggle("Watched candidates only", isOn: $watchedOnly)
                        Button("Clear filters", role: .destructive) { filterType = nil; watchedOnly = false }
                    }
                    .navigationTitle("Result filter")
                    .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { showFilters = false } } }
                }
                .presentationDetents([.medium])
            }
        }
    }
}

private struct ResultDetailScreen: View {
    let result: ScanResult
    @Binding var isWatched: Bool

    var body: some View {
        List {
            Section("Observation") {
                LabeledContent("Current", value: result.currentValue?.description ?? "-")
                LabeledContent("Previous", value: result.previousValue?.description ?? "Not sampled")
                LabeledContent("Initial", value: result.initialValue?.description ?? "-")
                LabeledContent("Type", value: result.dataType.displayName)
                LabeledContent("Region", value: result.regionName)
                LabeledContent("Offset", value: "+0x\(String(result.offset, radix: 16).uppercased())")
                LabeledContent("Observed", value: result.observedAt.formatted(date: .abbreviated, time: .standard))
            }
            Section {
                Toggle("Watch candidate", isOn: $isWatched).tint(StudioPalette.lime)
            }
        }
        .scrollContentBackground(.hidden)
        .background(StudioPalette.background)
        .navigationTitle("Candidate")
    }
}

private struct FilesScreen: View {
    @Binding var results: [ScanResult]
    let registry: MemoryRegionRegistry
    let scanner: MemoryScanner
    let snapshotStore: SnapshotStore
    let monitor: LiveValueMonitor
    @Binding var snapshots: [MemorySnapshot]
    @Binding var hasSession: Bool
    @Binding var errorText: String?
    @State private var name = "recovery-session"
    @State private var snapshotName = "Snapshot"
    @State private var format: ExportFormat = .json
    @State private var includeRawBytes = false
    @State private var includeObservations = false
    @State private var includePrevious = true
    @State private var includeRegions = true
    @State private var includeTimestamps = true
    @State private var exportDocument: DiagnosticFileDocument?
    @State private var isExporting = false
    @State private var receipt = ""
    @State private var comparison = ""
    @State private var monitorInterval = 1.0
    @State private var isMonitoring = false
    @State private var isPaused = false
    @State private var monitorTask: Task<Void, Never>?
    @State private var observations: [ValueObservation] = []
    @State private var sessionName = "recovery-session"
    @State private var sessions: [DiagnosticSession] = []
    @State private var renameTarget: MemorySnapshot?
    @State private var renameValue = ""
    @State private var isRenamingSnapshot = false

    var body: some View {
        NavigationStack {
            Form {
                Section("Live monitor") {
                    Stepper("Sample every \(monitorInterval.formatted(.number.precision(.fractionLength(1)))) s", value: $monitorInterval, in: 0.5...10, step: 0.5)
                    HStack {
                        if !isMonitoring {
                            Button("Start") { startMonitoring() }
                        } else {
                            Button(isPaused ? "Resume" : "Pause") {
                                Task {
                                    if isPaused { await monitor.resume() } else { await monitor.pause() }
                                    isPaused.toggle()
                                }
                            }
                            Button("Stop", role: .destructive) { stopMonitoring() }
                        }
                    }
                    ForEach(observations.prefix(12)) { observation in
                        HStack {
                            Circle().fill(observation.kind == .changed ? StudioPalette.amber : StudioPalette.cyan).frame(width: 6, height: 6)
                            Text(observation.regionName).lineLimit(1)
                            Spacer()
                            Text("\(observation.changedByteCount) B").font(.caption.monospacedDigit())
                        }
                        .font(.caption)
                    }
                }
                Section("Snapshot capture") {
                    TextField("Snapshot name", text: $snapshotName)
                    Button { Task { await capture() } } label: { Label("Capture registered buffers", systemImage: "camera") }
                        .disabled(snapshotName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    ForEach(snapshots) { snapshot in
                        VStack(alignment: .leading, spacing: 5) {
                            HStack {
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(snapshot.name).font(.subheadline.weight(.medium))
                                    Text("\(snapshot.capturedByteCount.formatted()) B · \(snapshot.createdAt.formatted(date: .numeric, time: .shortened))")
                                        .font(.caption2.monospaced()).foregroundStyle(.secondary)
                                }
                                Spacer()
                                Button {
                                    renameTarget = snapshot
                                    renameValue = snapshot.name
                                    isRenamingSnapshot = true
                                } label: {
                                    Image(systemName: "pencil").frame(width: 36, height: 36)
                                }
                                .accessibilityLabel("Rename snapshot \(snapshot.name)")
                                Button(role: .destructive) { Task { await delete(snapshot) } } label: {
                                    Image(systemName: "trash").frame(width: 36, height: 36)
                                }
                                .accessibilityLabel("Delete snapshot \(snapshot.name)")
                            }
                            Text("SHA-256 \(snapshot.checksum)").font(.system(size: 9, design: .monospaced)).foregroundStyle(.secondary).textSelection(.enabled)
                        }
                        .padding(.vertical, 3)
                    }
                    if snapshots.count >= 2 {
                        Button("Compare newest snapshots") { compareLatest() }
                        if !comparison.isEmpty { Text(comparison).font(.caption).foregroundStyle(.secondary) }
                    }
                }
                Section("Named export") {
                    TextField("Filename", text: $name).textInputAutocapitalization(.never).autocorrectionDisabled()
                    Picker("Format", selection: $format) {
                        ForEach(ExportFormat.allCases) { Text($0.rawValue.uppercased()).tag($0) }
                    }
                    Toggle("Include region details", isOn: $includeRegions)
                    Toggle("Include previous values", isOn: $includePrevious)
                    Toggle("Include timestamps", isOn: $includeTimestamps)
                    Toggle("Include raw snapshot bytes", isOn: $includeRawBytes)
                    Toggle("Include live observation history", isOn: $includeObservations)
                    Button { Task { await prepareExport() } } label: { Label("Export to Files", systemImage: "square.and.arrow.up") }
                        .disabled(name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    if !receipt.isEmpty { Text(receipt).font(.caption).foregroundStyle(StudioPalette.lime) }
                }
                Section("Session") {
                    TextField("Session name", text: $sessionName)
                    Button { saveSession() } label: { Label("Save scan session", systemImage: "externaldrive") }
                    Text("Saved sessions contain result metadata and snapshot references. Raw registered buffers are excluded.")
                        .font(.caption).foregroundStyle(.secondary)
                    ForEach(sessions) { session in
                        HStack {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(session.name)
                                Text("\(session.results.count) candidates · \(session.createdAt.formatted(date: .numeric, time: .shortened))")
                                    .font(.caption2).foregroundStyle(.secondary)
                            }
                            Spacer()
                            Button("Restore") { restoreSession(session) }
                            Button(role: .destructive) { deleteSession(session) } label: { Image(systemName: "trash") }
                                .accessibilityLabel("Delete session \(session.name)")
                        }
                    }
                }
            }
            .scrollContentBackground(.hidden)
            .background(StudioPalette.background)
            .navigationTitle("Files & reports")
            .fileExporter(isPresented: $isExporting, document: exportDocument, contentType: format.contentType, defaultFilename: outputFilename) { result in
                switch result {
                case .success(let url): receipt = "Exported \(url.lastPathComponent)."
                case .failure(let error): errorText = error.localizedDescription
                }
            }
            .task { await refreshSessions() }
            .alert("Rename snapshot", isPresented: $isRenamingSnapshot) {
                TextField("Snapshot name", text: $renameValue)
                Button("Rename") { renameSelectedSnapshot() }
                Button("Cancel", role: .cancel) { renameTarget = nil }
            } message: { Text("The snapshot checksum and captured bytes remain unchanged.") }
        }
    }

    private var outputFilename: String {
        let suffix = ".\(format.rawValue)"
        return name.lowercased().hasSuffix(suffix) ? name : name + suffix
    }

    private func prepareExport() async {
        do {
            var options = ExportOptions()
            options.includeRawBytes = includeRawBytes
            options.includeObservations = includeObservations
            options.includePreviousValues = includePrevious
            options.includeRegionInformation = includeRegions
            options.includeTimestamps = includeTimestamps
            let observations = includeObservations ? await monitor.observations() : []
            let data = try ExportManager().serializedData(
                payload: ExportPayload(results: results, snapshots: snapshots, observations: observations),
                format: format,
                options: options
            )
            exportDocument = DiagnosticFileDocument(data: data)
            isExporting = true
        } catch { errorText = error.localizedDescription }
    }

    @MainActor
    private func capture() async {
        do {
            let snapshot = try await snapshotStore.capture(name: snapshotName, regions: await registry.snapshots())
            snapshots.insert(snapshot, at: 0)
            receipt = "Captured \(snapshot.capturedByteCount.formatted()) bytes."
        } catch { errorText = error.localizedDescription }
    }

    @MainActor
    private func delete(_ snapshot: MemorySnapshot) async {
        do {
            try await snapshotStore.delete(snapshot.id)
            snapshots.removeAll { $0.id == snapshot.id }
        } catch { errorText = error.localizedDescription }
    }

    private func renameSelectedSnapshot() {
        guard let renameTarget else { return }
        Task {
            do {
                try await snapshotStore.rename(renameTarget.id, to: renameValue)
                snapshots = await snapshotStore.list()
                self.renameTarget = nil
            } catch { errorText = error.localizedDescription }
        }
    }

    @MainActor
    private func compareLatest() {
        guard snapshots.count >= 2 else { return }
        Task {
            do {
                let differences = try await snapshotStore.compare(snapshots[1].id, to: snapshots[0].id)
                comparison = "\(differences.count.formatted()) changed or added bytes."
            } catch { errorText = error.localizedDescription }
        }
    }

    private func saveSession() {
        Task {
            do {
                guard !sessionName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                    throw MemoryEngineError.invalidValue("session name")
                }
                let store = SessionStore()
                let session = DiagnosticSession(name: sessionName, selectedTypes: Array(Set(results.map(\.dataType))), results: results, snapshotIDs: snapshots.map(\.id), exportNames: [outputFilename])
                try await store.save(session)
                sessions = try await store.list()
                receipt = "Session metadata saved."
            } catch { errorText = error.localizedDescription }
        }
    }

    @MainActor
    private func refreshSessions() async {
        do { sessions = try await SessionStore().list() }
        catch { errorText = error.localizedDescription }
    }

    private func restoreSession(_ session: DiagnosticSession) {
        Task {
            do {
                let loaded = try await SessionStore().load(session.id)
                let restored = loaded.results.compactMap { record -> ScanResult? in
                    guard let current = record.currentValue else { return nil }
                    return ScanResult(
                        id: record.id,
                        regionID: record.regionID,
                        regionName: record.regionName,
                        offset: record.offset,
                        dataType: record.type,
                        initialValue: record.initialValue,
                        previousValue: record.previousValue,
                        currentValue: current,
                        observedAt: record.observedAt
                    )
                }
                await scanner.restoreCandidates(restored)
                results = restored
                hasSession = !restored.isEmpty && restored.allSatisfy { $0.dataType.width != nil }
                receipt = "Restored \(restored.count.formatted()) saved candidates."
            } catch { errorText = error.localizedDescription }
        }
    }

    private func deleteSession(_ session: DiagnosticSession) {
        Task {
            do {
                try await SessionStore().delete(session.id)
                sessions.removeAll { $0.id == session.id }
            } catch { errorText = error.localizedDescription }
        }
    }

    private func startMonitoring() {
        monitorTask = Task {
            do {
                let stream = try await monitor.start(registry: registry, interval: monitorInterval)
                await MainActor.run { isMonitoring = true; isPaused = false }
                for await observation in stream {
                    await MainActor.run {
                        observations.insert(observation, at: 0)
                        if observations.count > 200 { observations.removeLast(observations.count - 200) }
                    }
                }
                await MainActor.run { isMonitoring = false; isPaused = false }
            } catch {
                await MainActor.run { errorText = error.localizedDescription; isMonitoring = false }
            }
        }
    }

    private func stopMonitoring() {
        Task {
            await monitor.stop()
            monitorTask?.cancel()
            isMonitoring = false
            isPaused = false
        }
    }
}

private struct FloatingDiagnosticOverlay: View {
    @Binding var expanded: Bool
    @Binding var section: WorkspaceSection
    let regionCount: Int
    let resultCount: Int
    let availableSize: CGSize
    @State private var offset = CGSize.zero
    @GestureState private var translation = CGSize.zero

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 7) {
                Image(systemName: "waveform.path.ecg").foregroundStyle(StudioPalette.lime)
                Text("MS / LIVE").font(.system(size: 10, weight: .bold, design: .monospaced))
                Spacer(minLength: 4)
                Button { withAnimation(.easeInOut(duration: 0.22)) { expanded.toggle() } } label: {
                    Image(systemName: expanded ? "minus" : "arrow.up.left.and.arrow.down.right")
                        .frame(width: 32, height: 32).contentShape(Rectangle())
                }
                .accessibilityLabel(expanded ? "Minimize overlay" : "Expand overlay")
            }
            HStack(alignment: .firstTextBaseline, spacing: 4) {
                Text("\(resultCount)").font(.system(size: 20, weight: .semibold, design: .rounded).monospacedDigit())
                    .foregroundStyle(StudioPalette.lime)
                Text("candidates").font(.caption2).foregroundStyle(.secondary)
                Spacer(minLength: 1)
                Text("\(regionCount) REG").font(.system(size: 9, weight: .medium, design: .monospaced)).foregroundStyle(.secondary)
            }
            if expanded {
                Button { section = .scanner } label: {
                    Label("Open scanner", systemImage: "scope").font(.caption.weight(.semibold))
                        .frame(maxWidth: .infinity).frame(height: 35)
                }
                .buttonStyle(.borderedProminent).tint(StudioPalette.lime)
                Text("APP-OWNED REGIONS ONLY").font(.system(size: 8, weight: .medium, design: .monospaced)).foregroundStyle(.tertiary)
            } else {
                Button { section = .scanner } label: {
                    Image(systemName: "play.fill").font(.caption).frame(maxWidth: .infinity).frame(height: 30)
                }
                .buttonStyle(.borderedProminent).tint(StudioPalette.lime).accessibilityLabel("Open scanner")
            }
        }
        .padding(10)
        .frame(width: expanded ? 244 : 164)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 12))
        .overlay(RoundedRectangle(cornerRadius: 12).stroke(StudioPalette.lime.opacity(0.28), lineWidth: 1))
        .offset(x: offset.width + translation.width, y: offset.height + translation.height)
        .gesture(
            DragGesture(minimumDistance: 8)
                .updating($translation) { value, state, _ in state = value.translation }
                .onEnded { value in
                    let width: CGFloat = expanded ? 244 : 164
                    let height: CGFloat = expanded ? 132 : 100
                    offset = CGSize(
                        width: min(0, max(36 - availableSize.width + width, offset.width + value.translation.width)),
                        height: min(60, max(74 + height - availableSize.height, offset.height + value.translation.height))
                    )
                }
        )
    }
}

private struct SectionEyebrow: View {
    let title: String
    let count: Int
    var body: some View {
        HStack {
            Text(title).font(.system(size: 10, weight: .bold, design: .monospaced)).tracking(0.8).foregroundStyle(.secondary)
            Spacer()
            Text("\(count)").font(.caption.monospacedDigit().weight(.semibold)).foregroundStyle(StudioPalette.lime)
        }
    }
}

private struct DiagnosticFileDocument: FileDocument {
    static var readableContentTypes: [UTType] { [.data, .json, .commaSeparatedText, .xml, .zip, .plainText] }
    let data: Data
    init(data: Data) { self.data = data }
    init(configuration: ReadConfiguration) throws { data = configuration.file.regularFileContents ?? Data() }
    func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper { FileWrapper(regularFileWithContents: data) }
}

private extension ExportFormat {
    var contentType: UTType {
        switch self {
        case .json: .json
        case .csv: .commaSeparatedText
        case .xml: .xml
        case .zip: .zip
        case .md, .txt, .hex: .plainText
        case .bin: .data
        }
    }
}

private extension String {
    func leftPadded(to length: Int) -> String { String(repeating: "0", count: max(0, length - count)) + self }
}