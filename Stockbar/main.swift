import Cocoa

// Entry point for the application
// We use MainActor.assumeIsolated because we know the program starts on the main thread,
// and we need to initialize our @MainActor AppDelegate.
MainActor.assumeIsolated {
    let delegate = AppDelegate()
    NSApplication.shared.delegate = delegate
    _ = NSApplicationMain(CommandLine.argc, CommandLine.unsafeArgv)
}

