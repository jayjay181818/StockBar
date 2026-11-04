//
//  ChartAnnotationService.swift
//  Stockbar
//
//  Service for managing chart annotations and markers.
//  Persists annotations using Core Data via CoreDataStack.
//

import CoreData
import Foundation
import SwiftUI

// MARK: - Chart Annotation Model
struct ChartAnnotation: Identifiable, Equatable, Codable {
    let id: UUID
    let type: AnnotationType
    let date: Date
    let price: Double
    let text: String
    let symbol: String
    let colorHex: String
    
    var color: Color {
        Color(hex: colorHex) ?? .blue
    }
    
    enum AnnotationType: String, Codable {
        case text
        case earningsMarker
        case note
        case buyMarker
        case sellMarker
    }
    
    init(
        id: UUID = UUID(),
        type: AnnotationType,
        date: Date,
        price: Double,
        text: String,
        symbol: String,
        colorHex: String = "#0000FF"
    ) {
        self.id = id
        self.type = type
        self.date = date
        self.price = price
        self.text = text
        self.symbol = symbol
        self.colorHex = colorHex
    }
}

// MARK: - Service
@MainActor
class ChartAnnotationService: ObservableObject {
    static let shared = ChartAnnotationService()
    
    @Published private(set) var annotations: [ChartAnnotation] = []
    
    private let logger = Logger.shared
    private let storageURL: URL
    
    private init() {
        // Store in Application Support directory
        let directory = StockbarRuntimeStorage.stockbarApplicationSupportDirectory()
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        storageURL = directory.appendingPathComponent("chart_annotations.json")
        
        loadAnnotations()
    }
    
    // MARK: - CRUD Operations
    
    func addAnnotation(_ annotation: ChartAnnotation) {
        annotations.append(annotation)
        saveAnnotations()
        
        Task {
            await logger.info("📝 Added annotation: \(annotation.text) for \(annotation.symbol)")
        }
    }
    
    func removeAnnotation(id: UUID) {
        annotations.removeAll { $0.id == id }
        saveAnnotations()
        
        Task {
            await logger.info("📝 Removed annotation: \(id)")
        }
    }
    
    func updateAnnotation(_ annotation: ChartAnnotation) {
        if let index = annotations.firstIndex(where: { $0.id == annotation.id }) {
            annotations[index] = annotation
            saveAnnotations()
            Task { await logger.info("📝 Updated annotation: \(annotation.id)") }
        }
    }
    
    func clearAnnotations(for symbol: String) {
        annotations.removeAll { $0.symbol == symbol }
        saveAnnotations()
        Task { await logger.info("📝 Cleared annotations for \(symbol)") }
    }

    func getAnnotations(for symbol: String) -> [ChartAnnotation] {
        return annotations.filter { $0.symbol == symbol }
    }
    
    // MARK: - Persistence
    
    private func saveAnnotations() {
        do {
            let data = try JSONEncoder().encode(annotations)
            try data.write(to: storageURL, options: .atomic)
        } catch {
            Task {
                await logger.error("❌ Failed to save annotations: \(error.localizedDescription)")
            }
        }
    }
    
    private func loadAnnotations() {
        guard FileManager.default.fileExists(atPath: storageURL.path) else { return }

        do {
            let data = try Data(contentsOf: storageURL)
            let decoded = try Self.decodeAnnotations(from: data)
            annotations = decoded.annotations
            if decoded.droppedCount > 0 {
                // Keep the original so unreadable entries are not lost on the next save.
                preserveUnreadableFile(reason: "\(decoded.droppedCount) unreadable entries")
            }
            Task { [count = annotations.count] in
                await logger.info("✅ Loaded \(count) annotations from disk")
            }
        } catch {
            preserveUnreadableFile(reason: error.localizedDescription)
        }
    }

    /// Decodes entries one at a time so one bad entry does not discard the rest.
    nonisolated static func decodeAnnotations(from data: Data) throws -> (annotations: [ChartAnnotation], droppedCount: Int) {
        let entries = try JSONDecoder().decode([LossyAnnotation].self, from: data)
        let annotations = entries.compactMap(\.value)
        return (annotations, entries.count - annotations.count)
    }

    private struct LossyAnnotation: Decodable {
        let value: ChartAnnotation?

        init(from decoder: Decoder) throws {
            value = try? ChartAnnotation(from: decoder)
        }
    }

    /// Moves the file aside (or copies it when some entries loaded) so a later
    /// save cannot overwrite annotations that failed to load.
    private func preserveUnreadableFile(reason: String) {
        let stamp = Int(Date().timeIntervalSince1970)
        let backupURL = storageURL.deletingPathExtension()
            .appendingPathExtension("unreadable-\(stamp).json")
        do {
            try FileManager.default.copyItem(at: storageURL, to: backupURL)
        } catch {
            Task { await logger.error("❌ Could not preserve unreadable annotations file: \(error.localizedDescription)") }
            return
        }
        Task {
            await logger.error("❌ Annotations file was partly unreadable (\(reason)); kept a copy at \(backupURL.lastPathComponent)")
        }
    }
}

// MARK: - Annotation Entity (Stub for compilation if needed, but not used)
// Since we cannot modify .xcdatamodeld, we use JSON storage.
