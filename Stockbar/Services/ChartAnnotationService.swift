//
//  ChartAnnotationService.swift
//  Stockbar
//
//  Service for managing chart annotations and markers.
//  Persists annotations using Core Data via CoreDataStack.
//

import Foundation
import SwiftUI
import CoreData

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
        if let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first {
            let directory = appSupport.appendingPathComponent("Stockbar", isDirectory: true)
            try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            storageURL = directory.appendingPathComponent("chart_annotations.json")
        } else {
            // Fallback to documents
            let documents = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            storageURL = documents.appendingPathComponent("chart_annotations.json")
        }
        
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
            try data.write(to: storageURL)
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
            annotations = try JSONDecoder().decode([ChartAnnotation].self, from: data)
            
            Task {
                await logger.info("✅ Loaded \(annotations.count) annotations from disk")
            }
        } catch {
            Task {
                await logger.error("❌ Failed to load annotations: \(error.localizedDescription)")
            }
        }
    }
}

// MARK: - Annotation Entity (Stub for compilation if needed, but not used)
// Since we cannot modify .xcdatamodeld, we use JSON storage.


