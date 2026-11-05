import Foundation

/// Combines synchronous input changes before starting expensive chart work.
@MainActor
final class ChartReloadCoalescer {
    private var pending: Task<Void, Never>?

    func schedule(_ reload: @escaping @MainActor () -> Void) {
        guard pending == nil else { return }
        pending = Task { [weak self] in
            guard let self, !Task.isCancelled else { return }
            pending = nil
            reload()
        }
    }

    func cancel() {
        pending?.cancel()
        pending = nil
    }

    deinit { pending?.cancel() }
}
