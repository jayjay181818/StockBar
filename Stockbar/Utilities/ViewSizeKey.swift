import SwiftUI

/// A PreferenceKey for passing a view's size up the hierarchy.
struct ViewSizeKey: PreferenceKey {
    static let defaultValue: CGSize = .zero
    static func reduce(value: inout CGSize, nextValue: () -> CGSize) {
        value = nextValue()
    }
}
