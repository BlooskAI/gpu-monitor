import AppKit
import Combine
import Darwin
import Foundation
import Metal
import SwiftUI

private let accent = Color(red: 0.18, green: 0.88, blue: 0.60)
private let cyan = Color(red: 0.31, green: 0.77, blue: 0.92)
private let amber = Color(red: 0.96, green: 0.72, blue: 0.32)
private let violet = Color(red: 0.65, green: 0.55, blue: 0.98)
private let blooskaiLogo = Bundle.main.url(forResource: "blooskai-mark", withExtension: "png")
    .flatMap { NSImage(contentsOf: $0) }

/// How an accelerator reading should be read. `limited` means the device is
/// really there but macOS exposes no public counter for it, which must never be
/// rendered as a confident zero.
enum DeviceStatus {
    case ok
    case limited
    case absent
}

struct AcceleratorSample: Identifiable {
    var id: String { label }
    var label: String
    var name: String
    var utilization: Double?
    var status: DeviceStatus
    var note: String
}

struct ProcessSample: Identifiable {
    var id: Int32 { pid }
    var pid: Int32
    var name: String
    var memoryBytes: UInt64
    var cpuPercent: Double
}

struct SystemSnapshot {
    var gpuName = "Apple GPU"
    var gpuUtilization = 0.0
    var gpuTemperature: Double?
    var gpuAvailable = false
    var integrated: AcceleratorSample?
    var neural: AcceleratorSample?
    var topMemory: [ProcessSample] = []
    var topCPU: [ProcessSample] = []
    var cpuUtilization = 0.0
    var memoryUsed: UInt64 = 0
    var memoryTotal: UInt64 = 1
    var diskFree: Int64 = 0
    var diskTotal: Int64 = 1
    var networkDown = 0.0
    var networkUp = 0.0
    var sampledAt = Date()
}

/// Cumulative processor seconds per pid, kept between detail samples so CPU
/// share is a real measurement over the interval rather than a decayed average.
private struct ProcessAccounting {
    var cpuSeconds: [Int32: Double]
    var sampledAt: Date
}

private struct DetailResult {
    var integrated: AcceleratorSample?
    var neural: AcceleratorSample?
    var topMemory: [ProcessSample]
    var topCPU: [ProcessSample]
    var accounting: ProcessAccounting
}

private struct ProbeResult {
    var gpuName: String
    var gpuUtilization: Double?
    var gpuTemperature: Double?
    var cpuUtilization: Double
    var memoryUsed: UInt64
    var memoryTotal: UInt64
    var diskFree: Int64
    var diskTotal: Int64
    var networkIn: UInt64
    var networkOut: UInt64
    var detail: DetailResult?
}

@MainActor
final class SystemSampler: ObservableObject {
    @Published var snapshot = SystemSnapshot()
    @Published var gpuHistory = Array(repeating: 0.0, count: 60)
    @Published var cpuHistory = Array(repeating: 0.0, count: 60)

    private var timer: Timer?
    private var sampling = false
    private var previousNetwork: (input: UInt64, output: UInt64, date: Date)?

    /// Accelerator and process readings run every fifth pass. They spawn helper
    /// tools, so they are allowed to lag rather than cost something every tick.
    private static let detailEvery = 5
    private var tick = 0
    private var accounting: ProcessAccounting?

    init() {
        refresh()
        let refreshTimer = Timer(timeInterval: 2.0, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.refresh() }
        }
        RunLoop.main.add(refreshTimer, forMode: .common)
        timer = refreshTimer
    }

    deinit { timer?.invalidate() }

    func refresh(forceDetail: Bool = false) {
        guard !sampling else { return }
        sampling = true
        let wantsDetail = forceDetail || tick % Self.detailEvery == 0
        tick &+= 1
        let previousAccounting = accounting
        Task.detached(priority: .utility) {
            let probe = SystemProbe.sample(includeDetail: wantsDetail, accounting: previousAccounting)
            await MainActor.run { [weak self] in self?.apply(probe) }
        }
    }

    private func apply(_ probe: ProbeResult) {
        let now = Date()
        var down = 0.0
        var up = 0.0
        if let previousNetwork {
            let elapsed = max(now.timeIntervalSince(previousNetwork.date), 0.001)
            down = Double(probe.networkIn &- min(probe.networkIn, previousNetwork.input)) / elapsed
            up = Double(probe.networkOut &- min(probe.networkOut, previousNetwork.output)) / elapsed
        }
        previousNetwork = (probe.networkIn, probe.networkOut, now)

        // A pass that skipped the detail probe keeps the last known readings
        // rather than blanking the panel every other second.
        if let detail = probe.detail { accounting = detail.accounting }
        let previous = snapshot

        snapshot = SystemSnapshot(
            gpuName: probe.gpuName,
            gpuUtilization: probe.gpuUtilization ?? 0,
            gpuTemperature: probe.gpuTemperature,
            gpuAvailable: probe.gpuUtilization != nil,
            integrated: probe.detail?.integrated ?? previous.integrated,
            neural: probe.detail?.neural ?? previous.neural,
            topMemory: probe.detail?.topMemory ?? previous.topMemory,
            topCPU: probe.detail.map { $0.topCPU.isEmpty ? previous.topCPU : $0.topCPU } ?? previous.topCPU,
            cpuUtilization: probe.cpuUtilization,
            memoryUsed: probe.memoryUsed,
            memoryTotal: max(probe.memoryTotal, 1),
            diskFree: probe.diskFree,
            diskTotal: max(probe.diskTotal, 1),
            networkDown: down,
            networkUp: up,
            sampledAt: now
        )
        gpuHistory = appended(gpuHistory, probe.gpuUtilization ?? 0)
        cpuHistory = appended(cpuHistory, probe.cpuUtilization)
        sampling = false
    }

    private func appended(_ values: [Double], _ value: Double) -> [Double] {
        Array((values + [min(max(value, 0), 100)]).suffix(60))
    }
}

private enum SystemProbe {
    static func sample(includeDetail: Bool, accounting: ProcessAccounting?) -> ProbeResult {
        let gpu = gpuSample()
        let memory = memorySample()
        let disk = diskSample()
        let network = networkTotals()
        return ProbeResult(
            gpuName: gpu.name,
            gpuUtilization: gpu.utilization,
            gpuTemperature: gpu.temperature,
            cpuUtilization: cpuSample(),
            memoryUsed: memory.used,
            memoryTotal: memory.total,
            diskFree: disk.free,
            diskTotal: disk.total,
            networkIn: network.input,
            networkOut: network.output,
            detail: includeDetail ? detailSample(primaryGpu: gpu.name, utilization: gpu.utilization, accounting: accounting) : nil
        )
    }

    private static func detailSample(primaryGpu: String, utilization: Double?, accounting: ProcessAccounting?) -> DetailResult {
        let processes = processSample(accounting: accounting)
        return DetailResult(
            integrated: integratedSample(primaryGpu: primaryGpu, utilization: utilization),
            neural: neuralSample(),
            topMemory: Array(processes.all.sorted { $0.memoryBytes > $1.memoryBytes }.prefix(3)),
            topCPU: Array(processes.all.filter { $0.cpuPercent > 0 }.sorted { $0.cpuPercent > $1.cpuPercent }.prefix(3)),
            accounting: processes.accounting
        )
    }

    /// Apple silicon has a single unified device, so the integrated tile names
    /// the same GPU the hero card shows. Intel Macs can pair a low-power
    /// integrated device with a discrete one, and then the two differ.
    private static func integratedSample(primaryGpu: String, utilization: Double?) -> AcceleratorSample {
        let devices = MTLCopyAllDevices()
        let integrated = devices.first { $0.hasUnifiedMemory || $0.isLowPower }
        guard let device = integrated else {
            return AcceleratorSample(
                label: "IGPU",
                name: "no integrated GPU",
                utilization: nil,
                status: .absent,
                note: "discrete graphics only"
            )
        }
        let unified = device.name == primaryGpu
        return AcceleratorSample(
            label: "IGPU",
            name: device.name,
            utilization: unified ? utilization : nil,
            status: unified ? (utilization == nil ? .limited : .ok) : .limited,
            note: unified ? "unified with GPU" : "no per-device counter"
        )
    }

    /// Every Apple silicon Mac has a Neural Engine, but no public interface
    /// reports its load: powermetrics needs root. Report the device honestly as
    /// present-but-unmeasured rather than as idle.
    private static func neuralSample() -> AcceleratorSample {
        var isAppleSilicon: Int32 = 0
        var size = MemoryLayout<Int32>.size
        let present = sysctlbyname("hw.optional.arm64", &isAppleSilicon, &size, nil, 0) == 0 && isAppleSilicon == 1
        guard present else {
            return AcceleratorSample(
                label: "NPU",
                name: "no neural engine",
                utilization: nil,
                status: .absent,
                note: "Intel Mac"
            )
        }
        return AcceleratorSample(
            label: "NPU",
            name: "Apple Neural Engine",
            utilization: nil,
            status: .limited,
            note: "load needs root (powermetrics)"
        )
    }

    /// One ps call covers resident memory, the pid-to-name map and the
    /// cumulative processor time that the next pass turns into a percentage.
    private static func processSample(accounting: ProcessAccounting?) -> (all: [ProcessSample], accounting: ProcessAccounting) {
        let now = Date()
        let output = run("/bin/ps", ["-Aeo", "pid=,rss=,time=,comm="])
        var cpuSeconds: [Int32: Double] = [:]
        var samples: [ProcessSample] = []
        let cores = Double(max(ProcessInfo.processInfo.activeProcessorCount, 1))
        let elapsed = accounting.map { max(now.timeIntervalSince($0.sampledAt), 0.001) }

        for line in output.split(separator: "\n") {
            let fields = line.split(separator: " ", omittingEmptySubsequences: true)
            guard fields.count >= 4,
                  let pid = Int32(fields[0]),
                  let residentKilobytes = UInt64(fields[1]) else { continue }
            let seconds = processorSeconds(String(fields[2]))
            cpuSeconds[pid] = seconds

            var percent = 0.0
            if let elapsed, let previous = accounting?.cpuSeconds[pid], seconds > previous {
                percent = min((seconds - previous) / elapsed / cores * 100, 100)
            }
            let command = fields[3...].joined(separator: " ")
            samples.append(ProcessSample(
                pid: pid,
                name: (command as NSString).lastPathComponent,
                memoryBytes: residentKilobytes * 1024,
                cpuPercent: percent
            ))
        }
        return (samples, ProcessAccounting(cpuSeconds: cpuSeconds, sampledAt: now))
    }

    /// ps prints cumulative processor time as [[DD-]HH:]MM:SS.ss
    private static func processorSeconds(_ text: String) -> Double {
        var remainder = text
        var days = 0.0
        if let dash = remainder.firstIndex(of: "-") {
            days = Double(remainder[remainder.startIndex..<dash]) ?? 0
            remainder = String(remainder[remainder.index(after: dash)...])
        }
        let parts = remainder.split(separator: ":").map { Double($0) ?? 0 }
        let clock = parts.reduce(0.0) { $0 * 60 + $1 }
        return days * 86_400 + clock
    }

    private static func gpuSample() -> (name: String, utilization: Double?, temperature: Double?) {
        let name = MTLCreateSystemDefaultDevice()?.name ?? MTLCopyAllDevices().first?.name ?? "Apple GPU"
        let output = run("/usr/sbin/ioreg", ["-r", "-c", "IOAccelerator", "-l"])
            + run("/usr/sbin/ioreg", ["-r", "-n", "AGXAccelerator", "-l"])
        let utilizationPatterns = [
            #"\"Device Utilization %\"\s*=\s*(\d+(?:\.\d+)?)"#,
            #"\"GPU Activity\(%\)\"\s*=\s*(\d+(?:\.\d+)?)"#,
            #"\"Renderer Utilization %\"\s*=\s*(\d+(?:\.\d+)?)"#,
            #"\"GPU Core Utilization\"\s*=\s*(\d+(?:\.\d+)?)"#
        ]
        let temperaturePatterns = [
            #"\"Temperature\(C\)\"\s*=\s*(\d+(?:\.\d+)?)"#,
            #"\"GPU Temperature\"\s*=\s*(\d+(?:\.\d+)?)"#
        ]
        return (
            name,
            firstNumber(in: output, patterns: utilizationPatterns).map { min(max($0, 0), 100) },
            firstNumber(in: output, patterns: temperaturePatterns)
        )
    }

    private static func cpuSample() -> Double {
        let output = run("/usr/bin/top", ["-l", "1", "-n", "0", "-stats", "cpu"])
        if let idle = firstNumber(in: output, patterns: [#"(\d+(?:\.\d+)?)%\s*idle"#]) {
            return min(max(100 - idle, 0), 100)
        }
        return 0
    }

    private static func memorySample() -> (used: UInt64, total: UInt64) {
        let total = ProcessInfo.processInfo.physicalMemory
        let output = run("/usr/bin/vm_stat", [])
        let pageSize = UInt64(firstNumber(in: output, patterns: [#"page size of (\d+) bytes"#]) ?? 16_384)
        func pages(_ label: String) -> UInt64 {
            let escaped = NSRegularExpression.escapedPattern(for: label)
            return UInt64(firstNumber(in: output, patterns: [escaped + #"\s*:\s*(\d+)"#]) ?? 0)
        }
        let reclaimable = pages("Pages free") + pages("Pages inactive")
            + pages("Pages speculative") + pages("Pages purgeable")
        let available = min(total, reclaimable * pageSize)
        return (total - available, total)
    }

    private static func diskSample() -> (free: Int64, total: Int64) {
        do {
            let values = try URL(fileURLWithPath: "/").resourceValues(forKeys: [
                .volumeAvailableCapacityForImportantUsageKey,
                .volumeTotalCapacityKey
            ])
            return (values.volumeAvailableCapacityForImportantUsage ?? 0, Int64(values.volumeTotalCapacity ?? 1))
        } catch { return (0, 1) }
    }

    private static func networkTotals() -> (input: UInt64, output: UInt64) {
        var head: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&head) == 0, let first = head else { return (0, 0) }
        defer { freeifaddrs(head) }
        var input: UInt64 = 0
        var output: UInt64 = 0
        var cursor: UnsafeMutablePointer<ifaddrs>? = first
        while let current = cursor {
            let flags = Int32(current.pointee.ifa_flags)
            if (flags & IFF_LOOPBACK) == 0,
               let address = current.pointee.ifa_addr,
               address.pointee.sa_family == UInt8(AF_LINK),
               let raw = current.pointee.ifa_data {
                let data = raw.assumingMemoryBound(to: if_data.self).pointee
                input += UInt64(data.ifi_ibytes)
                output += UInt64(data.ifi_obytes)
            }
            cursor = current.pointee.ifa_next
        }
        return (input, output)
    }

    private static func run(_ executable: String, _ arguments: [String]) -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        do {
            try process.run()
            process.waitUntilExit()
            return String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        } catch { return "" }
    }

    private static func firstNumber(in text: String, patterns: [String]) -> Double? {
        let range = NSRange(text.startIndex..<text.endIndex, in: text)
        for pattern in patterns {
            guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]),
                  let match = regex.firstMatch(in: text, range: range),
                  match.numberOfRanges > 1,
                  let numberRange = Range(match.range(at: 1), in: text),
                  let number = Double(text[numberRange]) else { continue }
            return number
        }
        return nil
    }
}

struct Sparkline: View {
    let values: [Double]
    let color: Color

    var body: some View {
        GeometryReader { geometry in
            ZStack {
                LinearGradient(colors: [color.opacity(0.22), .clear], startPoint: .top, endPoint: .bottom)
                    .mask(line(in: geometry.size).stroke(style: StrokeStyle(lineWidth: 10, lineCap: .round)).blur(radius: 7))
                line(in: geometry.size)
                    .stroke(color, style: StrokeStyle(lineWidth: 2, lineCap: .round, lineJoin: .round))
            }
        }
    }

    private func line(in size: CGSize) -> Path {
        var path = Path()
        guard values.count > 1 else { return path }
        for (index, value) in values.enumerated() {
            let x = size.width * CGFloat(index) / CGFloat(values.count - 1)
            let y = size.height * CGFloat(1 - min(max(value, 0), 100) / 100)
            if index == 0 { path.move(to: CGPoint(x: x, y: y)) }
            else { path.addLine(to: CGPoint(x: x, y: y)) }
        }
        return path
    }
}

struct MetricCard: View {
    let title: String
    let value: String
    let progress: Double?
    let color: Color
    let symbol: String

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Label(title, systemImage: symbol)
                    .font(.system(size: 10, weight: .semibold, design: .rounded))
                    .foregroundStyle(color)
                Spacer()
                Text(value)
                    .font(.system(size: 15, weight: .semibold, design: .rounded))
                    .monospacedDigit()
            }
            if let progress {
                GeometryReader { geometry in
                    ZStack(alignment: .leading) {
                        Capsule().fill(.white.opacity(0.07))
                        Capsule().fill(color.gradient)
                            .frame(width: geometry.size.width * CGFloat(min(max(progress, 0), 1)))
                    }
                }.frame(height: 5)
            }
        }
        .padding(13)
        .background(RoundedRectangle(cornerRadius: 15).fill(.white.opacity(0.045)))
        .overlay(RoundedRectangle(cornerRadius: 15).stroke(.white.opacity(0.07), lineWidth: 1))
    }
}

struct AcceleratorTile: View {
    let sample: AcceleratorSample?
    let color: Color
    let fallbackLabel: String

    private var resolved: AcceleratorSample {
        sample ?? AcceleratorSample(label: fallbackLabel, name: "probing", utilization: nil, status: .limited, note: "")
    }

    private var tint: Color {
        resolved.status == .ok ? color : .secondary
    }

    var body: some View {
        let value = resolved
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(value.label)
                    .font(.system(size: 9, weight: .bold, design: .rounded))
                    .foregroundStyle(tint)
                Spacer()
                Text(value.utilization.map { "\(Int($0.rounded()))%" } ?? "—")
                    .font(.system(size: 15, weight: .semibold, design: .rounded))
                    .monospacedDigit()
                    .foregroundStyle(value.status == .ok ? .primary : .secondary)
            }
            Text(value.name)
                .font(.system(size: 8, weight: .medium, design: .rounded))
                .foregroundStyle(.secondary)
                .lineLimit(1)
            GeometryReader { geometry in
                ZStack(alignment: .leading) {
                    Capsule().fill(.white.opacity(0.07))
                    Capsule().fill(color.gradient)
                        .frame(width: geometry.size.width * CGFloat(min(max((value.utilization ?? 0) / 100, 0), 1)))
                }
            }.frame(height: 4)
            Text(value.note.isEmpty ? " " : value.note)
                .font(.system(size: 7, weight: .medium, design: .rounded))
                .foregroundStyle(.tertiary)
                .lineLimit(1)
        }
        .padding(11)
        .background(RoundedRectangle(cornerRadius: 14).fill(.white.opacity(0.045)))
        .overlay(RoundedRectangle(cornerRadius: 14).stroke(.white.opacity(0.07), lineWidth: 1))
    }
}

struct ResidentRow: View {
    let label: String
    let color: Color
    let summary: String

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text(label)
                .font(.system(size: 8, weight: .bold, design: .rounded))
                .foregroundStyle(color)
                .frame(width: 34, alignment: .leading)
            Text(summary)
                .font(.system(size: 8, weight: .medium, design: .rounded))
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.tail)
            Spacer(minLength: 0)
        }
    }
}

struct DashboardView: View {
    @EnvironmentObject var sampler: SystemSampler

    private var memoryProgress: Double {
        Double(sampler.snapshot.memoryUsed) / Double(max(sampler.snapshot.memoryTotal, 1))
    }

    var body: some View {
        let value = sampler.snapshot
        VStack(spacing: 14) {
            HStack(spacing: 11) {
                if let logo = blooskaiLogo {
                    Image(nsImage: logo).resizable().scaledToFit().frame(width: 34, height: 34)
                        .accessibilityLabel("BlooskAI")
                        .help("Visit BlooskAI, a division of Biznique")
                        .onTapGesture { NSWorkspace.shared.open(URL(string: "https://www.bizniqueinc.com/blooskai")!) }
                } else {
                    ZStack {
                        Circle().fill(accent.opacity(0.16)).frame(width: 34, height: 34)
                        Image(systemName: "gauge.with.dots.needle.67percent").foregroundStyle(accent)
                    }
                }
                VStack(alignment: .leading, spacing: 2) {
                    Text("GPU MONITOR").font(.system(size: 13, weight: .bold, design: .rounded))
                    Text("BlooskAI / LOCAL HARDWARE").font(.system(size: 8, weight: .medium, design: .rounded)).foregroundStyle(.secondary)
                }
                Spacer()
                HStack(spacing: 6) {
                    Circle().fill(value.gpuAvailable ? accent : .red).frame(width: 7, height: 7)
                    Text(value.gpuAvailable ? "LIVE" : "LIMITED")
                        .font(.system(size: 9, weight: .bold, design: .rounded))
                        .foregroundStyle(value.gpuAvailable ? accent : .red)
                }
            }

            VStack(alignment: .leading, spacing: 10) {
                Text(value.gpuName.uppercased())
                    .font(.system(size: 10, weight: .semibold, design: .rounded))
                    .foregroundStyle(accent)
                    .lineLimit(1)
                HStack(alignment: .firstTextBaseline) {
                    Text(value.gpuAvailable ? "\(Int(value.gpuUtilization.rounded()))%" : "—")
                        .font(.system(size: 48, weight: .semibold, design: .rounded))
                        .monospacedDigit()
                    Text("GPU LOAD").font(.system(size: 9, weight: .bold, design: .rounded)).foregroundStyle(.secondary)
                    Spacer()
                    if let temperature = value.gpuTemperature {
                        VStack(alignment: .trailing, spacing: 2) {
                            Text("\(Int(temperature.rounded()))°C").font(.system(size: 21, weight: .semibold, design: .rounded)).foregroundStyle(amber)
                            Text("TEMPERATURE").font(.system(size: 8, weight: .bold, design: .rounded)).foregroundStyle(.secondary)
                        }
                    }
                }
                Sparkline(values: sampler.gpuHistory, color: accent).frame(height: 58)
            }
            .padding(16)
            .background(
                RoundedRectangle(cornerRadius: 19)
                    .fill(LinearGradient(colors: [accent.opacity(0.13), .white.opacity(0.045)], startPoint: .topLeading, endPoint: .bottomTrailing))
            )
            .overlay(RoundedRectangle(cornerRadius: 19).stroke(.white.opacity(0.08), lineWidth: 1))

            HStack(spacing: 10) {
                AcceleratorTile(sample: value.integrated, color: cyan, fallbackLabel: "IGPU")
                AcceleratorTile(sample: value.neural, color: violet, fallbackLabel: "NPU")
            }

            LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 10) {
                MetricCard(title: "CPU", value: "\(Int(value.cpuUtilization.rounded()))%", progress: value.cpuUtilization / 100, color: cyan, symbol: "cpu")
                MetricCard(title: "MEMORY", value: "\(Int((memoryProgress * 100).rounded()))%", progress: memoryProgress, color: amber, symbol: "memorychip")
                MetricCard(title: "DISK", value: formatBytes(UInt64(max(value.diskFree, 0))) + " free", progress: nil, color: cyan, symbol: "internaldrive")
                MetricCard(title: "NETWORK", value: "↓" + formatRate(value.networkDown), progress: nil, color: accent, symbol: "arrow.up.arrow.down")
            }

            VStack(alignment: .leading, spacing: 7) {
                HStack {
                    Text("RESIDENT").font(.system(size: 8, weight: .bold, design: .rounded)).foregroundStyle(accent)
                    Spacer()
                    Text("TOP CONSUMERS").font(.system(size: 7, weight: .medium, design: .rounded)).foregroundStyle(.tertiary)
                }
                ResidentRow(label: "GPU", color: accent, summary: "per-process GPU use is not exposed on macOS")
                ResidentRow(label: "RAM", color: amber, summary: summarize(value.topMemory, byMemory: true))
                ResidentRow(label: "CPU", color: cyan, summary: summarize(value.topCPU, byMemory: false))
            }
            .padding(13)
            .background(RoundedRectangle(cornerRadius: 15).fill(.white.opacity(0.045)))
            .overlay(RoundedRectangle(cornerRadius: 15).stroke(.white.opacity(0.07), lineWidth: 1))

            HStack {
                Text("CRASH-SAFE • LOGIN READY")
                Spacer()
                Text(value.sampledAt, style: .time)
            }
            .font(.system(size: 8, weight: .semibold, design: .rounded))
            .foregroundStyle(.secondary)
        }
        .padding(18)
        .frame(width: 350, height: 628)
        .background(.ultraThinMaterial)
        .background(Color.black.opacity(0.55))
        .clipShape(RoundedRectangle(cornerRadius: 24, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 24, style: .continuous)
                .stroke(LinearGradient(colors: [accent.opacity(0.7), cyan.opacity(0.35), .white.opacity(0.08)], startPoint: .topLeading, endPoint: .bottomTrailing), lineWidth: 1)
        )
        .shadow(color: .black.opacity(0.45), radius: 24, y: 12)
        .preferredColorScheme(.dark)
    }

    private func summarize(_ processes: [ProcessSample], byMemory: Bool) -> String {
        guard !processes.isEmpty else { return "measuring…" }
        return processes.map { process in
            byMemory
                ? "\(process.name) \(formatBytes(process.memoryBytes))"
                : "\(process.name) \(String(format: "%.1f", process.cpuPercent))%"
        }.joined(separator: "   ")
    }

    private func formatBytes(_ value: UInt64) -> String {
        ByteCountFormatter.string(fromByteCount: Int64(value), countStyle: .file)
    }

    private func formatRate(_ value: Double) -> String {
        ByteCountFormatter.string(fromByteCount: Int64(max(value, 0)), countStyle: .file) + "/s"
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private let sampler = SystemSampler()
    private var panel: NSPanel?
    private var statusItem: NSStatusItem?

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        createPanel()
        createStatusItem()
    }

    private func createPanel() {
        let panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 350, height: 628),
            styleMask: [.borderless, .nonactivatingPanel, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        panel.contentView = NSHostingView(rootView: DashboardView().environmentObject(sampler))
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.isMovableByWindowBackground = true
        panel.hidesOnDeactivate = false
        panel.collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle]
        panel.level = NSWindow.Level(rawValue: Int(CGWindowLevelForKey(.desktopIconWindow)) + 1)
        panel.setFrameAutosaveName("UtilsGpuMonitorPanel")
        if !panel.setFrameUsingName("UtilsGpuMonitorPanel"), let screen = NSScreen.main {
            let frame = screen.visibleFrame
            panel.setFrameOrigin(NSPoint(x: frame.maxX - 370, y: frame.maxY - 648))
        }
        panel.orderFrontRegardless()
        self.panel = panel
    }

    private func createStatusItem() {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        item.button?.image = NSImage(systemSymbolName: "gauge.with.dots.needle.67percent", accessibilityDescription: "GPU Monitor")
        let menu = NSMenu()
        menu.addItem(withTitle: "Show / Hide GPU Monitor", action: #selector(togglePanel), keyEquivalent: "g")
        menu.addItem(withTitle: "Refresh Now", action: #selector(refreshNow), keyEquivalent: "r")
        menu.addItem(withTitle: "BlooskAI website", action: #selector(openWebsite), keyEquivalent: "")
        menu.addItem(.separator())
        menu.addItem(withTitle: "Quit GPU Monitor", action: #selector(quit), keyEquivalent: "q")
        for item in menu.items { item.target = self }
        item.menu = menu
        statusItem = item
    }

    @objc private func togglePanel() {
        guard let panel else { return }
        panel.isVisible ? panel.orderOut(nil) : panel.orderFrontRegardless()
    }

    @objc private func refreshNow() { sampler.refresh(forceDetail: true) }
    @objc private func openWebsite() { NSWorkspace.shared.open(URL(string: "https://www.bizniqueinc.com/blooskai")!) }
    @objc private func quit() { NSApp.terminate(nil) }
}

let application = NSApplication.shared
let applicationDelegate = AppDelegate()
application.delegate = applicationDelegate
application.run()
