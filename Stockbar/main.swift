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

// An acceptance run adopts the Folync settings its bootstrap left in its root,
// before anything reads the defaults. Never in a normal run or under XCTest.
do {
    try StockbarAcceptancePreflight.adoptSeededSettingsIfPresent(
        runtime: StockbarRuntimeStorage.acceptance,
        defaults: StockbarRuntimeStorage.userDefaults
    )
    // The made-up instrument events and alerts, when asked for, must pass their checks
    // before the app starts; otherwise the copy stops here.
    _ = try StockbarAcceptanceEventsFixture.load(
        options: StockbarAcceptanceLaunchOptions.current,
        runtime: StockbarRuntimeStorage.acceptance
    )
    _ = try StockbarAcceptanceAlertsFixture.load(
        options: StockbarAcceptanceLaunchOptions.current,
        runtime: StockbarRuntimeStorage.acceptance
    )
    // The made-up local holdings, when asked for, go into a fresh copy's own
    // defaults before the data model reads them, and Folync is switched off there.
    try StockbarAcceptanceHoldingsFixture.seedIfRequested(
        options: StockbarAcceptanceLaunchOptions.current,
        runtime: StockbarRuntimeStorage.acceptance,
        defaults: StockbarRuntimeStorage.userDefaults
    )
} catch {
    FileHandle.standardError.write(Data("Stockbar acceptance launch failed: \(error.localizedDescription)\n".utf8))
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
