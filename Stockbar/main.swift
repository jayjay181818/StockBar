import Cocoa

do {
    if let status = try StockbarAcceptancePreflight.runIfRequested(
        output: { FileHandle.standardOutput.write($0) }
    ) {
        exit(Int32(status))
    }
    if let status = try StockbarAcceptancePreflight.bootstrapIfRequested(
        output: { FileHandle.standardOutput.write($0) }
    ) {
        exit(Int32(status))
    }
} catch {
    FileHandle.standardError.write(Data("Stockbar acceptance preflight failed: \(error.localizedDescription)\n".utf8))
    exit(2)
}

// Entry point for the application
// We use MainActor.assumeIsolated because we know the program starts on the main thread,
// and we need to initialize our @MainActor AppDelegate.
MainActor.assumeIsolated {
    let delegate = AppDelegate()
    NSApplication.shared.delegate = delegate
    _ = NSApplicationMain(CommandLine.argc, CommandLine.unsafeArgv)
}
