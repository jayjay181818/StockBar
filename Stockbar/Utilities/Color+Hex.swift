//
//  Color+Hex.swift
//  Stockbar
//
//  Shared Color extension for Hex conversion.
//

import SwiftUI

extension Color {
    /// Initialize Color from hex string
    init?(hex: String) {
        var hexSanitized = hex.trimmingCharacters(in: .whitespacesAndNewlines)
        hexSanitized = hexSanitized.replacingOccurrences(of: "#", with: "")

        var rgb: UInt64 = 0

        guard Scanner(string: hexSanitized).scanHexInt64(&rgb) else { return nil }

        self.init(
            red: Double((rgb & 0xFF0000) >> 16) / 255.0,
            green: Double((rgb & 0x00FF00) >> 8) / 255.0,
            blue: Double(rgb & 0x0000FF) / 255.0
        )
    }
    
    /// Convert Color to hex string
    func toHex() -> String? {
        // Try getting components from cgColor (works for most colors in SwiftUI)
        // Note: This might fail for dynamic system colors like .primary, .blue etc. unless resolved in environment
        // But for custom colors created from hex, it works.
        #if os(macOS)
        guard let components = NSColor(self).cgColor.components, components.count >= 3 else {
            return nil
        }
        #else
        guard let components = UIColor(self).cgColor.components, components.count >= 3 else {
            return nil
        }
        #endif
        
        let r = Float(components[0])
        let g = Float(components[1])
        let b = Float(components[2])
        
        return String(format: "#%02lX%02lX%02lX", lroundf(r * 255), lroundf(g * 255), lroundf(b * 255))
    }
}

