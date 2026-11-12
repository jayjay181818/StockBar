// Samples the memory, CPU and wakeup counters of one process and every process
// it started (for Stockbar: the app and its Python helpers).
//
//   proc_usage <pid> [--interval seconds] [--duration seconds] [--series file]
//   proc_usage <pid> --wait-window seconds
//
// It reads kernel accounting through proc_pid_rusage, which does not attach
// to, pause or signal the target. Memory is the physical footprint, the figure
// Activity Monitor shows; resident size understates it because compressed
// pages are left out. A duration of 0 takes one sample and prints no rates.
//
// Energy is the kernel's own estimate of what the process's CPU use cost, in
// joules. It leaves out the display, the graphics processor and the network,
// so it is not the whole of the battery drain; it needs no administrator
// rights, which a whole-system reading (powermetrics) does.
//
// Output is key=value lines. "helper" means every descendant of <pid>; while no
// helper is running it counts as 0 MB. --series also writes one line per sample
// to a file: seconds since the first sample, app MB, helper MB.
//
// --wait-window instead waits until the process has an ordinary window on
// screen and prints the clock time at which it appeared.
import CoreGraphics
import Darwin
import Foundation

struct Usage {
    let footprint: UInt64
    let lifetimePeak: UInt64
    let resident: UInt64
    let cpuSeconds: Double
    let wakeups: UInt64
    let diskWritten: UInt64
    let energyJoules: Double
}

var timebase = mach_timebase_info_data_t()
mach_timebase_info(&timebase)

func usage(of pid: pid_t) -> Usage? {
    var info = rusage_info_v6()
    let status = withUnsafeMutablePointer(to: &info) { pointer in
        pointer.withMemoryRebound(to: rusage_info_t?.self, capacity: 1) { rebound in
            proc_pid_rusage(pid, RUSAGE_INFO_V6, rebound)
        }
    }
    guard status == 0 else { return nil }
    let ticks = Double(info.ri_user_time + info.ri_system_time)
    return Usage(
        footprint: info.ri_phys_footprint,
        lifetimePeak: info.ri_lifetime_max_phys_footprint,
        resident: info.ri_resident_size,
        cpuSeconds: ticks * Double(timebase.numer) / Double(timebase.denom) / 1_000_000_000,
        wakeups: info.ri_pkg_idle_wkups + info.ri_interrupt_wkups,
        diskWritten: info.ri_diskio_byteswritten,
        energyJoules: Double(info.ri_energy_nj) / 1_000_000_000
    )
}

func children(of pid: pid_t) -> [pid_t] {
    var buffer = [pid_t](repeating: 0, count: 1024)
    let count = proc_listchildpids(pid, &buffer, Int32(buffer.count * MemoryLayout<pid_t>.size))
    return count > 0 ? Array(buffer.prefix(Int(count))) : []
}

func descendants(of root: pid_t) -> [pid_t] {
    var found: [pid_t] = []
    var queue = [root]
    while let next = queue.popLast() {
        for child in children(of: next) where !found.contains(child) {
            found.append(child)
            queue.append(child)
        }
    }
    return found
}

func megabytes(_ bytes: UInt64) -> Double { Double(bytes) / 1_048_576 }
func median(_ values: [Double]) -> Double {
    guard !values.isEmpty else { return 0 }
    let sorted = values.sorted()
    let middle = sorted.count / 2
    return sorted.count % 2 == 1 ? sorted[middle] : (sorted[middle - 1] + sorted[middle]) / 2
}
func emit(_ key: String, _ value: Double, digits: Int = 1) {
    print("\(key)=\(String(format: "%.\(digits)f", value))")
}
func fail(_ message: String) -> Never {
    FileHandle.standardError.write(Data((message + "\n").utf8))
    exit(64)
}

var arguments = Array(CommandLine.arguments.dropFirst())
guard let first = arguments.first, let root = pid_t(first), root > 0 else {
    fail("Usage: proc_usage <pid> [--interval seconds] [--duration seconds] [--series file] | --wait-window seconds")
}
arguments.removeFirst()
var interval = 5.0
var duration = 0.0
var seriesPath: String?
var windowWait: Double?
while arguments.count >= 2 {
    if arguments[0] == "--series" {
        seriesPath = arguments[1]
    } else {
        guard let value = Double(arguments[1]), value >= 0 else { fail("Not a number: \(arguments[1])") }
        switch arguments[0] {
        case "--interval": interval = max(value, 0.1)
        case "--duration": duration = value
        case "--wait-window": windowWait = value
        default: fail("Unknown option: \(arguments[0])")
        }
    }
    arguments.removeFirst(2)
}
guard arguments.isEmpty else { fail("Unknown option: \(arguments[0])") }

/// Whether the process has an ordinary window on screen. Menu-bar items sit on
/// a higher layer and do not count.
func hasWindowOnScreen(_ pid: pid_t) -> Bool {
    let options: CGWindowListOption = [.optionOnScreenOnly, .excludeDesktopElements]
    let windows = (CGWindowListCopyWindowInfo(options, kCGNullWindowID) as? [[String: Any]]) ?? []
    return windows.contains { window in
        (window[kCGWindowOwnerPID as String] as? Int).map { pid_t($0) } == pid
            && (window[kCGWindowLayer as String] as? Int) == 0
    }
}

if let windowWait {
    let deadline = Date().addingTimeInterval(windowWait)
    while Date() < deadline {
        if hasWindowOnScreen(root) {
            print(String(format: "window_shown_at=%.3f", Date().timeIntervalSince1970))
            exit(0)
        }
        if kill(root, 0) != 0, errno == ESRCH { fail("Process \(root) exited before showing a window.") }
        Thread.sleep(forTimeInterval: 0.02)
    }
    fail("Process \(root) showed no window within \(windowWait) s.")
}

var appFootprints: [Double] = []
var appResidents: [Double] = []
var helperFootprints: [Double] = []
var sampleTimes: [Double] = []
var firstApp: Usage?
var lastApp: Usage?
// CPU already used by a helper when it was first seen. A helper that starts
// inside the window is counted from zero, so its start-up cost is included.
var helperBaseline: [pid_t: Double] = [:]
var helperLatest: [pid_t: Double] = [:]
let start = DispatchTime.now()
func secondsSince(_ moment: DispatchTime) -> Double {
    Double(DispatchTime.now().uptimeNanoseconds - moment.uptimeNanoseconds) / 1_000_000_000
}
var sampleIndex = 0

while true {
    guard let app = usage(of: root) else {
        if sampleIndex == 0 { fail("Process \(root) is not running or cannot be read.") }
        break
    }
    if firstApp == nil { firstApp = app }
    lastApp = app
    sampleTimes.append(secondsSince(start))
    appFootprints.append(megabytes(app.footprint))
    appResidents.append(megabytes(app.resident))
    var helperTotal = 0.0
    for pid in descendants(of: root) {
        guard let helper = usage(of: pid) else { continue }
        helperTotal += megabytes(helper.footprint)
        if helperBaseline[pid] == nil { helperBaseline[pid] = sampleIndex == 0 ? helper.cpuSeconds : 0 }
        helperLatest[pid] = helper.cpuSeconds
    }
    helperFootprints.append(helperTotal)
    sampleIndex += 1
    let next = Double(sampleIndex) * interval
    if next > duration { break }
    let wait = next - secondsSince(start)
    if wait > 0 { Thread.sleep(forTimeInterval: wait) }
}

guard let firstApp, let lastApp else { fail("No samples taken.") }
let windowSeconds = secondsSince(start)
let totals = zip(appFootprints, helperFootprints).map { $0 + $1 }
let alive = helperFootprints.filter { $0 > 0 }

if let seriesPath {
    let lines = (0..<sampleIndex).map { index in
        String(format: "%.1f %.1f %.1f", sampleTimes[index], appFootprints[index], helperFootprints[index])
    }
    do {
        try (["# seconds app_mb helper_mb"] + lines).joined(separator: "\n").appending("\n")
            .write(toFile: seriesPath, atomically: true, encoding: .utf8)
    } catch {
        fail("Could not write \(seriesPath): \(error.localizedDescription)")
    }
}

print("pid=\(root)")
print("samples=\(sampleIndex)")
// Either changes what the system does for a window, so runs that differ in
// them are not compared.
print("display_asleep=\(CGDisplayIsAsleep(CGMainDisplayID()) != 0 ? 1 : 0)")
let session = CGSessionCopyCurrentDictionary() as? [String: Any]
print("screen_locked=\((session?["CGSSessionScreenIsLocked"] as? Bool) == true ? 1 : 0)")
emit("window_s", windowSeconds)
emit("app_footprint_mb_median", median(appFootprints))
emit("app_footprint_mb_min", appFootprints.min() ?? 0)
emit("app_footprint_mb_max", appFootprints.max() ?? 0)
emit("app_lifetime_peak_mb", megabytes(lastApp.lifetimePeak))
emit("app_resident_mb_median", median(appResidents))
// Later half of the window against the earlier half: growth while idle. It
// means little over a minute and is what a long run is for.
if sampleIndex >= 4 {
    let half = sampleIndex / 2
    emit("app_footprint_drift_mb", median(Array(appFootprints.suffix(half))) - median(Array(appFootprints.prefix(half))))
}
emit("helper_alive_fraction", Double(alive.count) / Double(sampleIndex), digits: 2)
emit("helper_footprint_mb_median_alive", median(alive))
emit("total_footprint_mb_mean", totals.reduce(0, +) / Double(totals.count))
emit("total_footprint_mb_max", totals.max() ?? 0)
// CPU the app had used before the first sample: its launch cost when the
// sampling starts a fixed time after launch.
emit("app_cpu_s_before_window", firstApp.cpuSeconds, digits: 2)
emit("app_energy_j_before_window", firstApp.energyJoules, digits: 2)
if sampleIndex > 1, windowSeconds > 0 {
    let perMinute = 60 / windowSeconds
    let helperCPU = helperLatest.reduce(0.0) { $0 + $1.value - (helperBaseline[$1.key] ?? 0) }
    emit("app_cpu_s_per_min", (lastApp.cpuSeconds - firstApp.cpuSeconds) * perMinute, digits: 3)
    emit("app_wakeups_per_min", Double(lastApp.wakeups - firstApp.wakeups) * perMinute)
    emit("app_power_mw", (lastApp.energyJoules - firstApp.energyJoules) / windowSeconds * 1000, digits: 2)
    emit("app_disk_written_mb_per_min", megabytes(lastApp.diskWritten - firstApp.diskWritten) * perMinute, digits: 3)
    emit("helper_cpu_s_per_min", helperCPU * perMinute, digits: 3)
}
