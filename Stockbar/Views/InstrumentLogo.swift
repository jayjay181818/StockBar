import SwiftUI

/// Decorative only. The adjoining ticker remains the accessible instrument label.
struct InstrumentLogo: View {
    let symbol: String
    let size: CGFloat
    @AppStorage(InstrumentLogoStore.enabledKey, store: StockbarRuntimeStorage.userDefaults) private var enabled = false

    var body: some View {
        if enabled {
            InstrumentLogoTile(symbol: symbol)
                .id(symbol)
                .frame(width: size, height: size)
                .accessibilityHidden(true)
        }
    }
}

private struct InstrumentLogoTile: View {
    let symbol: String
    @State private var image: CGImage?

    var body: some View {
        Group {
            if let image {
                Image(decorative: image, scale: 2)
                    .resizable()
                    .scaledToFit()
                    .padding(2)
                    .background(.white, in: RoundedRectangle(cornerRadius: 4)) // Keep brand artwork readable in dark mode.
            } else {
                Image(systemName: "building.2")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .task {
            let result = await InstrumentLogoStore.shared.image(for: symbol)
            if !Task.isCancelled { image = result }
        }
    }
}
