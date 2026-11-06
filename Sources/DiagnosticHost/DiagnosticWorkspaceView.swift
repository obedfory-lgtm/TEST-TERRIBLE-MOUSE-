import MemoryEngine
import Combine
import SwiftUI
import UniformTypeIdentifiers

private enum WorkspaceTab: String, CaseIterable, Identifiable, Hashable {
    case dashboard = "Dashboard"
    case scanner = "Scanner"
    case memory = "Memory"
    case results = "Results"
    case files = "Files"

    var id: String { rawValue }
    var symbol: String {
        switch self {
        case .dashboard: "square.grid.2x2"
        case .scanner: "waveform.path"
        case .memory: "memorychip"
        case .results: "list.bullet.rectangle"
        case .files: "folder"
        }
    }
}

private struct EmptyState: View {
    let title: String
    let symbol: String
    let message: String?

    var body: some View {
        VStack(spacing: 10) {
            Image(systemName: symbol).font(.largeTitle).foregroundStyle(.secondary)
            Text(title).font(.headline)
            if let message {
                Text(message).font(.subheadline).foregroundStyle(.secondary).multilineTextAlignment(.center)
            }
        }
        .padding()
        .accessibilityElement(children: .combine)
    }
}

public struct DiagnosticWorkspaceView: View {
    @State private var registry: MemoryRegionRegistry
    @State private var scanner = MemoryScanner()
    @State private var snapshotStore = SnapshotStore()
    @State private var regions: [MemoryRegionInfo] = []
    @State private var results: [ScanResult] = []
    @State private var selectedResultIDs = Set<String>()
    @State private var snapshots: [MemorySnapshot] = []
    @State private var selectedTab: WorkspaceTab = .dashboard
    @State private var overlayExpanded = false
    @State private var errorMessage: String?

    public init(registry: MemoryRegionRegistry = MemoryRegionRegistry()) {
        _registry = State(initialValue: registry)
    }

    var body: some View {
        ZStack(alignment: .bottomTrailing) {
            TabView(selection: $selectedTab) {
                DashboardView(
                    regions: regions,
                    resultCount: results.count,
                    registry: registry,
                    errorMessage: $errorMessage
                )
                    .tabItem { Label("Dashboard", systemImage: WorkspaceTab.dashboard.symbol) }
                    .tag(WorkspaceTab.dashboard)
                ScannerView(registry: registry, scanner: scanner, results: $results, errorMessage: $errorMessage)
                    .tabItem { Label("Scanner", systemImage: WorkspaceTab.scanner.symbol) }
                    .tag(WorkspaceTab.scanner)
                MemoryMapView(regions: regions, registry: registry)
                    .tabItem { Label("Memory", systemImage: WorkspaceTab.memory.symbol) }
                    .tag(WorkspaceTab.memory)
                ResultsView(results: results, selectedIDs: $selectedResultIDs)
                    .tabItem { Label("Results", systemImage: WorkspaceTab.results.symbol) }
                    .tag(WorkspaceTab.results)
                ExportView(
                    results: results,
                    selectedIDs: selectedResultIDs,
                    registry: registry,
                    snapshotStore: snapshotStore,
                    snapshots: $snapshots
                )
                    .tabItem { Label("Files", systemImage: WorkspaceTab.files.symbol) }
                    .tag(WorkspaceTab.files)
            }
            .tint(Color.cyan)
            .task { await refreshRegions() }

            FloatingDiagnosticPanel(
                expanded: $overlayExpanded,
                selectedTab: $selectedTab,
                regionCount: regions.count,
                resultCount: results.count
            )
            .padding(.trailing, 12)
            .padding(.bottom, 68)
        }
        .alert("Diagnostic error", isPresented: Binding(
            get: { errorMessage != nil },
            set: { if !$0 { errorMessage = nil } }
        )) {
            Button("Dismiss", role: .cancel) { errorMessage = nil }
        } message: {
            Text(errorMessage ?? "")
        }
        .task {
            do {
                try await DiagnosticHostSampleData.register(in: registry)
                try await snapshotStore.restore()
            } catch {
                errorMessage = error.localizedDescription
            }
            while !Task.isCancelled {
                await refreshRegions()
                await refreshSnapshots()
                try? await Task.sleep(for: .seconds(2))
            }
        }
    }

    @MainActor
    private func refreshRegions() async {
        regions = await registry.regions()
    }

    @MainActor
    private func refreshSnapshots() async {
        snapshots = await snapshotStore.list()
    }
}

private struct DashboardView: View {
    let regions: [MemoryRegionInfo]
    let resultCount: Int
    let registry: MemoryRegionRegistry
    @Binding var errorMessage: String?

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    Text("Authorized diagnostics")
                        .font(.largeTitle.bold())
                    Text("Only buffers explicitly registered by this host application can be inspected.")
                        .foregroundStyle(.secondary)
                    HStack(spacing: 12) {
                        MetricCard(title: "Regions", value: "\(regions.count)", symbol: "memorychip")
                        MetricCard(title: "Candidates", value: "\(resultCount)", symbol: "scope")
                    }
                    GroupBox("Session status") {
                        VStack(alignment: .leading, spacing: 10) {
                            Label(
                                regions.isEmpty ? "No registered regions" : "Ready to inspect",
                                systemImage: regions.isEmpty ? "lock.shield" : "checkmark.shield"
                            )
                            .frame(maxWidth: .infinity, alignment: .leading)
                            Button("Increment sample Int32") {
                                Task {
                                    do {
                                        try await DiagnosticHostSampleData.incrementFirstValue(in: registry)
                                    } catch {
                                        errorMessage = error.localizedDescription
                                    }
                                }
                            }
                            .disabled(!regions.contains { $0.id == DiagnosticHostSampleData.numericRegionID })
                        }
                        .padding(.vertical, 4)
                    }
                    if regions.isEmpty {
                        EmptyState(
                            title: "No buffers registered",
                            symbol: "memorychip",
                            message: "The host must register an owned diagnostic buffer before scans are available."
                        )
                        .padding(.top, 16)
                    }
                }
                .padding()
            }
            .navigationTitle("Memory Studio")
        }
    }
}

private struct MetricCard: View {
    let title: String
    let value: String
    let symbol: String

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label(title, systemImage: symbol).font(.caption).foregroundStyle(.secondary)
            Text(value).font(.title2.monospacedDigit().bold())
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding()
        .background(.white.opacity(0.06), in: RoundedRectangle(cornerRadius: 14))
    }
}

private struct ScannerView: View {
    let registry: MemoryRegionRegistry
    let scanner: MemoryScanner
    @Binding var results: [ScanResult]
    @Binding var errorMessage: String?
    @State private var type: MemoryDataType = .int32
    @State private var firstMode = "Exact"
    @State private var nextMode = "Changed"
    @State private var input = ""
    @State private var upperBound = ""
    @State private var tolerance = "0"
    @State private var byteOrder: ByteOrder = .littleEndian
    @State private var alignment: MemoryScanAlignment = .natural
    @State private var resultLimit = "250000"
    @State private var status = "Ready"
    @State private var isScanning = false
    @State private var hasActiveScan = false
    @State private var scanTask: Task<Void, Never>?
    @StateObject private var scanProgress = ScanProgressState()
    @State private var elapsedSeconds: TimeInterval?
    @State private var wasTruncated = false

    private let firstModes = ["Exact", "Greater than", "Less than", "Between", "Unknown"]
    private let nextModes = [
        "Changed", "Unchanged", "Increased", "Decreased", "Increased by",
        "Decreased by", "Same as initial", "Exact", "Greater than", "Less than", "Between"
    ]

    var body: some View {
        NavigationStack {
            Form {
                Section("Scan configuration") {
                    Picker("Data type", selection: $type) {
                        ForEach(MemoryDataType.allCases.filter(\.isNumeric)) { type in
                            Text(type.displayName).tag(type)
                        }
                    }
                    Picker("Byte order", selection: $byteOrder) {
                        Text("Little endian").tag(ByteOrder.littleEndian)
                        Text("Big endian").tag(ByteOrder.bigEndian)
                    }
                    Picker("Alignment", selection: $alignment) {
                        Text("Natural").tag(MemoryScanAlignment.natural)
                        Text("Every byte").tag(MemoryScanAlignment.everyByte)
                    }
                    TextField("Float tolerance", text: $tolerance)
                        .keyboardType(.decimalPad)
                    TextField("Result limit", text: $resultLimit)
                        .keyboardType(.numberPad)
                    if !hasActiveScan {
                        Picker("First scan", selection: $firstMode) {
                            ForEach(firstModes, id: \.self) { Text($0) }
                        }
                    } else {
                        Picker("Next scan", selection: $nextMode) {
                            ForEach(nextModes, id: \.self) { Text($0) }
                        }
                    }
                    let mode = hasActiveScan ? nextMode : firstMode
                    if mode != "Unknown" {
                        TextField(mode == "Between" ? "Lower bound / value" : "Value", text: $input)
                            .keyboardType(.numbersAndPunctuation)
                            .accessibilityLabel("Scan value")
                    }
                    if mode == "Between" {
                        TextField("Upper bound", text: $upperBound)
                            .keyboardType(.numbersAndPunctuation)
                    }
                }
                Section {
                    if isScanning {
                        Button("Cancel scan", role: .destructive) {
                            scanTask?.cancel()
                        }
                    } else {
                        Button(hasActiveScan ? "Next Scan" : "New Scan") {
                            scanTask = Task { await runScan() }
                        }
                        if hasActiveScan {
                            Button("New Scan", role: .destructive) {
                                Task {
                                    await scanner.clear()
                                    results = []
                                    hasActiveScan = false
                                    status = "Ready"
                                }
                            }
                        }
                    }
                    Button("Clear results", role: .destructive) {
                        scanTask?.cancel()
                        Task {
                            await scanner.clear()
                            results = []
                            hasActiveScan = false
                            status = "Ready"
                        }
                    }
                    .disabled(isScanning)
                }
                Section("Progress") {
                    Text(status).foregroundStyle(.secondary)
                    Text("\(results.count) candidates").monospacedDigit()
                    if let progress = scanProgress.value, progress.total > 0 {
                        ProgressView(value: Double(progress.processed), total: Double(progress.total))
                        Text("\(progress.processed.formatted()) / \(progress.total.formatted()) bytes · \(progress.matches.formatted()) matches")
                            .font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                    } else if isScanning {
                        ProgressView()
                    }
                    if let elapsedSeconds {
                        Text("Elapsed: \(elapsedSeconds.formatted(.number.precision(.fractionLength(2)))) s")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    if wasTruncated {
                        Label("Results truncated at the configured limit", systemImage: "exclamationmark.triangle")
                            .font(.caption).foregroundStyle(.yellow)
                    }
                }
            }
            .navigationTitle("Scanner")
        }
    }

    @MainActor
    private func runScan() async {
        isScanning = true
        defer {
            isScanning = false
            scanTask = nil
        }
        let startedAt = Date()
        scanProgress.value = nil
        wasTruncated = false
        do {
            let regions = try await registry.snapshots()
            guard !regions.isEmpty else {
                status = "Register a host-owned buffer to begin."
                return
            }
            if let toleranceValue = Double(tolerance), toleranceValue >= 0 {
                await scanner.setTolerance(toleranceValue)
            } else {
                throw MemoryEngineError.invalidValue(tolerance)
            }
            guard let limit = Int(resultLimit), limit > 0 else {
                throw MemoryEngineError.invalidValue(resultLimit)
            }
            if !hasActiveScan {
                let criterion: FirstScanCriterion
                switch firstMode {
                case "Greater than": criterion = .greaterThan(input)
                case "Less than": criterion = .lessThan(input)
                case "Between": criterion = .between(input, upperBound)
                case "Unknown": criterion = .unknown
                default: criterion = .exact(input)
                }
                results = try await scanner.firstScan(
                    regions: regions,
                    type: type,
                    criterion: criterion,
                    byteOrder: byteOrder,
                    alignment: alignment,
                    resultLimit: limit,
                    cancellation: { Task.isCancelled },
                    progress: { update in
                        Task { @MainActor in scanProgress.value = update }
                    }
                )
                hasActiveScan = true
            } else {
                let criterion: NextScanCriterion
                switch nextMode {
                case "Unchanged": criterion = .unchanged
                case "Increased": criterion = .increased
                case "Decreased": criterion = .decreased
                case "Increased by": criterion = .increasedBy(input)
                case "Decreased by": criterion = .decreasedBy(input)
                case "Same as initial": criterion = .sameAsInitial
                case "Exact": criterion = .exact(input)
                case "Greater than": criterion = .greaterThan(input)
                case "Less than": criterion = .lessThan(input)
                case "Between": criterion = .between(input, upperBound)
                default: criterion = .changed
                }
                results = try await scanner.nextScan(
                    regions: regions,
                    criterion: criterion,
                    byteOrder: byteOrder,
                    cancellation: { Task.isCancelled },
                    progress: { update in
                        Task { @MainActor in scanProgress.value = update }
                    }
                )
            }
            wasTruncated = await scanner.resultsWereTruncated()
            status = "Scan complete"
        } catch is CancellationError {
            status = "Scan cancelled"
        } catch {
            errorMessage = error.localizedDescription
            status = "Scan failed"
        }
        elapsedSeconds = Date().timeIntervalSince(startedAt)
    }
}

@MainActor
private final class ScanProgressState: ObservableObject {
    @Published var value: ScanProgress?
}

private struct MemoryMapView: View {
    let regions: [MemoryRegionInfo]
    let registry: MemoryRegionRegistry
    @State private var query = ""

    private var filteredRegions: [MemoryRegionInfo] {
        guard !query.isEmpty else { return regions }
        return regions.filter { $0.name.localizedCaseInsensitiveContains(query) }
    }

    var body: some View {
        NavigationStack {
            List(filteredRegions) { region in
                NavigationLink {
                    MemoryRegionHexView(region: region, registry: registry)
                } label: {
                    VStack(alignment: .leading, spacing: 5) {
                        Text(region.name).font(.headline)
                        Text("\(region.byteCount.formatted()) bytes · \(region.isWritable ? "read/write" : "read-only")")
                            .font(.subheadline).foregroundStyle(.secondary)
                        if let type = region.dataType {
                            Text(type.displayName).font(.caption).foregroundStyle(.secondary)
                        }
                        if let baseAddress = region.baseAddress {
                            Text("Base: 0x\(String(baseAddress, radix: 16).uppercased())")
                                .font(.caption.monospaced()).foregroundStyle(.secondary)
                        }
                        Text(region.id.uuidString).font(.caption2.monospaced()).foregroundStyle(.tertiary)
                    }
                }
            }
            .overlay {
                if filteredRegions.isEmpty {
                    EmptyState(title: "No registered memory", symbol: "memorychip", message: nil)
                }
            }
            .searchable(text: $query, prompt: "Filter regions")
            .navigationTitle("Memory Viewer")
        }
    }
}

private struct MemoryRegionHexView: View {
    let region: MemoryRegionInfo
    let registry: MemoryRegionRegistry
    @State private var bytes = Data()
    @State private var selectedOffset: Int?
    @State private var errorMessage: String?

    private let pageSize = 4_096
    private var nextOffset: Int { bytes.count }

    var body: some View {
        List {
            Section("Registered region") {
                LabeledContent("Size", value: "\(region.byteCount.formatted()) bytes")
                LabeledContent("Access", value: region.isWritable ? "Read / write" : "Read only")
                LabeledContent("Identifier", value: region.id.uuidString)
            }
            Section("Hex and ASCII") {
                ForEach(stride(from: 0, to: bytes.count, by: 16).map { $0 }, id: \.self) { offset in
                    let chunk = bytes[offset..<min(offset + 16, bytes.count)]
                    Button {
                        selectedOffset = offset
                    } label: {
                        HStack(alignment: .firstTextBaseline, spacing: 10) {
                            Text(String(format: "%08X", offset))
                                .foregroundStyle(.secondary)
                            Text(chunk.map { String(format: "%02X", $0) }.joined(separator: " "))
                                .foregroundStyle(.primary)
                                .frame(maxWidth: .infinity, alignment: .leading)
                            Text(String(decoding: chunk.map { (0x20...0x7E).contains($0) ? $0 : 0x2E }, as: UTF8.self))
                                .foregroundStyle(.secondary)
                        }
                        .font(.system(.caption, design: .monospaced))
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Offset \(offset), bytes \(chunk.map { String(format: "%02X", $0) }.joined(separator: " "))")
                }
                if nextOffset < region.byteCount {
                    Button("Load next \(min(pageSize, region.byteCount - nextOffset).formatted()) bytes") {
                        Task { await loadNextPage() }
                    }
                }
            }
            if let selectedOffset {
                Section("Selected byte") {
                    let absoluteOffset = selectedOffset
                    let value = bytes[absoluteOffset]
                    LabeledContent("Offset", value: "0x\(String(absoluteOffset, radix: 16).uppercased())")
                    LabeledContent("Hex", value: String(format: "%02X", value))
                    LabeledContent("Unsigned", value: "\(value)")
                    LabeledContent("Bits", value: String(value, radix: 2).leftPadded(to: 8, with: "0"))
                }
            }
            if let errorMessage {
                Section("Read error") { Text(errorMessage).foregroundStyle(.red) }
            }
        }
        .navigationTitle(region.name)
        .navigationBarTitleDisplayMode(.inline)
        .task { if bytes.isEmpty { await loadNextPage() } }
    }

    @MainActor
    private func loadNextPage() async {
        guard nextOffset < region.byteCount else { return }
        let end = min(nextOffset + pageSize, region.byteCount)
        do {
            let page = try await registry.read(region: region.id, range: nextOffset..<end)
            bytes.append(page)
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}

private struct ResultsView: View {
    let results: [ScanResult]
    @Binding var selectedIDs: Set<String>
    @State private var visibleLimit = 500
    @State private var editMode: EditMode = .inactive

    var body: some View {
        NavigationStack {
            List(selection: $selectedIDs) {
                ForEach(results.prefix(visibleLimit)) { result in
                    VStack(alignment: .leading, spacing: 4) {
                        Text(result.currentValue?.description ?? "—")
                            .font(.body.monospaced())
                        Text("\(result.regionName) · +0x\(String(result.offset, radix: 16).uppercased()) · \(result.dataType.displayName)")
                            .font(.caption).foregroundStyle(.secondary)
                        if let previous = result.previousValue {
                            Text("Previous: \(previous.description)")
                                .font(.caption2).foregroundStyle(.tertiary)
                        }
                    }
                    .accessibilityElement(children: .combine)
                    .tag(result.id)
                }
                if visibleLimit < results.count {
                    Button("Load next \(min(500, results.count - visibleLimit)) results") {
                        visibleLimit = min(results.count, visibleLimit + 500)
                    }
                }
            }
            .overlay {
                if results.isEmpty {
                    EmptyState(title: "No results", symbol: "scope", message: "Run a scan to populate this list.")
                }
            }
            .navigationTitle("Results (\(results.count))")
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    Menu {
                        Button("Select all") { selectedIDs = Set(results.map(\.id)) }
                        Button("Clear selection") { selectedIDs.removeAll() }
                    } label: {
                        Image(systemName: "checklist")
                    }
                    .accessibilityLabel("Selection actions")
                }
                ToolbarItem(placement: .navigationBarTrailing) { EditButton() }
            }
            .environment(\.editMode, $editMode)
        }
    }
}

private struct ExportView: View {
    let results: [ScanResult]
    let selectedIDs: Set<String>
    let registry: MemoryRegionRegistry
    let snapshotStore: SnapshotStore
    @Binding var snapshots: [MemorySnapshot]
    @State private var filename = "diagnostic-session"
    @State private var snapshotName = "Snapshot"
    @State private var format: ExportFormat = .json
    @State private var exportDocument: DiagnosticExportDocument?
    @State private var isExporting = false
    @State private var errorMessage: String?
    @State private var statusMessage: String?
    @State private var includePrevious = true
    @State private var includeMetadata = true
    @State private var includeTimestamps = true
    @State private var includeRegions = true
    @State private var includeRawBytes = false

    var body: some View {
        NavigationStack {
            Form {
                Section("Snapshots") {
                    TextField("Snapshot name", text: $snapshotName)
                    Button("Capture registered regions") {
                        Task { await captureSnapshot() }
                    }
                    .disabled(snapshotName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    ForEach(snapshots) { snapshot in
                        HStack {
                            VStack(alignment: .leading, spacing: 3) {
                                Text(snapshot.name)
                                Text("\(snapshot.capturedByteCount.formatted()) bytes · \(snapshot.checksum.prefix(12))…")
                                    .font(.caption).foregroundStyle(.secondary)
                            }
                            Spacer()
                            Button(role: .destructive) {
                                Task {
                                    do {
                                        try await snapshotStore.delete(snapshot.id)
                                        await refreshSnapshots()
                                    } catch {
                                        errorMessage = error.localizedDescription
                                    }
                                }
                            } label: {
                                Image(systemName: "trash")
                            }
                            .accessibilityLabel("Delete snapshot \(snapshot.name)")
                        }
                    }
                }
                Section("Export") {
                    TextField("Filename", text: $filename)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                    Picker("Format", selection: $format) {
                        ForEach(ExportFormat.allCases) { Text($0.fileExtension.uppercased()).tag($0) }
                    }
                    Toggle("Include metadata", isOn: $includeMetadata)
                    Toggle("Include timestamps", isOn: $includeTimestamps)
                    Toggle("Include previous values", isOn: $includePrevious)
                    Toggle("Include region information", isOn: $includeRegions)
                    Toggle("Include raw snapshot bytes", isOn: $includeRawBytes)
                    Button("Prepare export") {
                        do {
                            var options = ExportOptions()
                            options.includeMetadata = includeMetadata
                            options.includeTimestamps = includeTimestamps
                            options.includePreviousValues = includePrevious
                            options.includeRegionInformation = includeRegions
                            options.includeRawBytes = includeRawBytes
                            let data = try ExportManager().serializedData(
                                payload: ExportPayload(results: selectedResults, snapshots: snapshots),
                                format: format,
                                options: options
                            )
                            exportDocument = DiagnosticExportDocument(data: data)
                            isExporting = true
                        } catch {
                            errorMessage = error.localizedDescription
                        }
                    }
                    .disabled(filename.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
                if let statusMessage {
                    Section("Export status") {
                        Text(statusMessage).foregroundStyle(.secondary)
                    }
                }
                Section("Destination") {
                    Text("Exports use the iOS document picker. The chosen filename and format are retained.")
                        .font(.footnote).foregroundStyle(.secondary)
                }
            }
            .navigationTitle("Files")
            .fileExporter(
                isPresented: $isExporting,
                document: exportDocument,
                contentType: format.contentType,
                defaultFilename: exportFilename
            ) { result in
                switch result {
                case .success(let url):
                    statusMessage = "Exported \(url.lastPathComponent)."
                case .failure(let error):
                    errorMessage = error.localizedDescription
                }
            }
            .alert("Export failed", isPresented: Binding(
                get: { errorMessage != nil },
                set: { if !$0 { errorMessage = nil } }
            )) {
                Button("Dismiss", role: .cancel) { errorMessage = nil }
            } message: {
                Text(errorMessage ?? "")
            }
        }

        @MainActor
        private func captureSnapshot() async {
            do {
                let captured = try await snapshotStore.capture(
                    name: snapshotName,
                    regions: try await registry.snapshots()
                )
                snapshots.insert(captured, at: 0)
                statusMessage = "Captured \(captured.capturedByteCount.formatted()) bytes."
            } catch {
                errorMessage = error.localizedDescription
            }
        }

        @MainActor
        private func refreshSnapshots() async {
            snapshots = await snapshotStore.list()
        }

        private var selectedResults: [ScanResult] {
            let selected = results.filter { selectedIDs.contains($0.id) }
            return selected.isEmpty ? results : selected
        }

        private var exportFilename: String {
            let suffix = ".\(format.fileExtension)"
            return filename.lowercased().hasSuffix(suffix) ? filename : filename + suffix
        }
    }
}

private struct FloatingDiagnosticPanel: View {
    @Binding var expanded: Bool
    @Binding var selectedTab: WorkspaceTab
    let regionCount: Int
    let resultCount: Int
    @State private var offset = CGSize.zero
    @GestureState private var dragTranslation = CGSize.zero

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Image(systemName: "waveform.path.ecg").foregroundStyle(.cyan)
                Text("Memory Studio").font(.caption.bold())
                Spacer()
                Button {
                    expanded.toggle()
                } label: {
                    Image(systemName: expanded ? "minus" : "arrow.up.left.and.arrow.down.right")
                        .frame(minWidth: 44, minHeight: 44)
                }
                .accessibilityLabel(expanded ? "Minimize diagnostic panel" : "Expand diagnostic panel")
            }
            Text("\(resultCount) candidates · \(regionCount) regions")
                .font(.caption2).foregroundStyle(.secondary)
                .lineLimit(1)
            Button(expanded ? "Open scanner" : "Scan") { selectedTab = .scanner }
                .buttonStyle(.borderedProminent)
                .tint(.cyan)
                .frame(maxWidth: .infinity)
                .frame(minHeight: 40)
            if expanded {
                Text("Registered host buffers only")
                    .font(.caption2).foregroundStyle(.tertiary)
            }
        }
        .padding(12)
        .frame(width: expanded ? 230 : 190)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 16))
        .overlay(RoundedRectangle(cornerRadius: 16).stroke(.white.opacity(0.15)))
        .offset(x: offset.width + dragTranslation.width, y: offset.height + dragTranslation.height)
        .gesture(
            DragGesture()
                .updating($dragTranslation) { value, state, _ in state = value.translation }
                .onEnded { value in
                    offset = CGSize(
                        width: min(120, max(-120, offset.width + value.translation.width)),
                        height: min(240, max(-240, offset.height + value.translation.height))
                    )
                }
        )
    }
}

private struct DiagnosticExportDocument: FileDocument {
    static var readableContentTypes: [UTType] {
        [.data, .json, .commaSeparatedText, .xml, .zip, .plainText]
    }
    let data: Data

    init(data: Data) { self.data = data }

    init(configuration: ReadConfiguration) throws {
        data = configuration.file.regularFileContents ?? Data()
    }

    func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper {
        FileWrapper(regularFileWithContents: data)
    }
}

private extension ExportFormat {
    var contentType: UTType {
        switch self {
        case .json: .json
        case .csv: .commaSeparatedText
        case .xml: .xml
        case .zip: .zip
        case .markdown: .plainText
        case .txt, .hex: .plainText
        case .bin: .data
        }
    }
}

private extension String {
    func leftPadded(to length: Int, with character: Character) -> String {
        String(repeating: String(character), count: max(0, length - count)) + self
    }
}
