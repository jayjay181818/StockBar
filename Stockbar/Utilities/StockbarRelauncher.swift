import AppKit
import Foundation

enum StockbarRelaunchError: Error, Equatable, LocalizedError {
    case unavailableUnderXCTest
    case incompleteAcceptanceRuntime

    var errorDescription: String? {
        switch self {
        case .unavailableUnderXCTest:
            return "Stockbar can't relaunch itself while tests are running."
        case .incompleteAcceptanceRuntime:
            return "Stockbar couldn't keep its isolated test storage for a relaunch."
        }
    }
}

/// Relaunches the running app bundle once this process has exited.
///
/// A short-lived `/bin/sh` helper waits (up to a minute) for this process to
/// exit and only then starts the app, so two copies never share the store.
/// Values reach the script as arguments, never interpolated into it.
///
/// Normal runs reopen the bundle through LaunchServices (`open`), which never
/// carries acceptance variables. Acceptance runs start the executable directly
/// with the acceptance root, run ID and disabled live providers set
/// explicitly, so the relaunched app cannot fall back to production storage.
enum StockbarRelauncher {
    struct LaunchPlan: Equatable {
        let executable: URL
        let arguments: [String]
        let environment: [String: String]
    }

    static let waitScript = """
    pid="$1"; shift
    n=0
    while /bin/kill -0 "$pid" 2>/dev/null; do
      n=$((n + 1)); [ "$n" -gt 300 ] && exit 1
      /bin/sleep 0.2
    done
    exec "$@"
    """

    static func launchPlan(
        runtime: StockbarAcceptanceRuntime,
        bundleURL: URL,
        executableURL: URL,
        processIdentifier: Int32,
        environment: [String: String]
    ) throws -> LaunchPlan {
        guard !runtime.isAutomaticXCTestIsolation else { throw StockbarRelaunchError.unavailableUnderXCTest }
        let shell = URL(fileURLWithPath: "/bin/sh")
        let prefix = ["-c", waitScript, "stockbar-relaunch", String(processIdentifier)]

        guard runtime.isEnabled else {
            var cleaned = environment
            for key in ["STOCKBAR_ACCEPTANCE_ROOT", "STOCKBAR_ACCEPTANCE_RUN_ID", "STOCKBAR_DISABLE_LIVE_PROVIDERS"] {
                cleaned.removeValue(forKey: key)
            }
            return LaunchPlan(
                executable: shell,
                arguments: prefix + ["/usr/bin/open", bundleURL.path],
                environment: cleaned
            )
        }

        guard let root = runtime.root, let runID = runID(of: runtime) else {
            throw StockbarRelaunchError.incompleteAcceptanceRuntime
        }
        var acceptanceEnvironment = environment
        acceptanceEnvironment["STOCKBAR_ACCEPTANCE_ROOT"] = root.path
        acceptanceEnvironment["STOCKBAR_ACCEPTANCE_RUN_ID"] = runID
        acceptanceEnvironment["STOCKBAR_DISABLE_LIVE_PROVIDERS"] = "1"
        return LaunchPlan(
            executable: shell,
            arguments: prefix + [executableURL.path],
            environment: acceptanceEnvironment
        )
    }

    private static func runID(of runtime: StockbarAcceptanceRuntime) -> String? {
        guard let runID = runtime.runID, !runID.isEmpty else { return nil }
        return runID
    }

    /// Starts the helper, then quits. Throws without quitting if the helper
    /// cannot be started.
    @MainActor
    static func relaunch() throws {
        guard let executableURL = Bundle.main.executableURL else {
            throw StockbarRelaunchError.incompleteAcceptanceRuntime
        }
        let plan = try launchPlan(
            runtime: StockbarRuntimeStorage.acceptance,
            bundleURL: Bundle.main.bundleURL,
            executableURL: executableURL,
            processIdentifier: ProcessInfo.processInfo.processIdentifier,
            environment: ProcessInfo.processInfo.environment
        )
        let process = Process()
        process.executableURL = plan.executable
        process.arguments = plan.arguments
        process.environment = plan.environment
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try process.run()
        NSApp.terminate(nil)
    }
}
