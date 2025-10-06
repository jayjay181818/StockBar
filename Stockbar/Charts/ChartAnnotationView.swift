//
//  ChartAnnotationView.swift
//  Stockbar
//
//  Created by Stockbar Development Team on 10/4/25.
//

import SwiftUI

// MARK: - Annotation Data Model

struct ChartAnnotation: Identifiable, Equatable {
    let id: UUID
    var type: AnnotationType
    var position: CGPoint
    var text: String
    var timestamp: Date
    var color: Color

    enum AnnotationType: String, Codable {
        case text
        case earningsMarker
        case note
    }

    init(
        id: UUID = UUID(),
        type: AnnotationType,
        position: CGPoint,
        text: String,
        timestamp: Date = Date(),
        color: Color = .blue
    ) {
        self.id = id
        self.type = type
        self.position = position
        self.text = text
        self.timestamp = timestamp
        self.color = color
    }
}

// MARK: - Annotation Manager

@MainActor
class AnnotationManager: ObservableObject {
    @Published var annotations: [ChartAnnotation] = []
    @Published var selectedAnnotation: ChartAnnotation?
    @Published var isEditingAnnotation: Bool = false

    func addAnnotation(_ annotation: ChartAnnotation) {
        annotations.append(annotation)
        Task {
            await Logger.shared.debug("📝 Annotation added: \(annotation.text) at \(annotation.position)")
        }
    }

    func removeAnnotation(_ annotation: ChartAnnotation) {
        annotations.removeAll { $0.id == annotation.id }
        if selectedAnnotation?.id == annotation.id {
            selectedAnnotation = nil
        }
        Task {
            await Logger.shared.debug("📝 Annotation removed: \(annotation.id)")
        }
    }

    func updateAnnotation(_ annotation: ChartAnnotation) {
        if let index = annotations.firstIndex(where: { $0.id == annotation.id }) {
            annotations[index] = annotation
            Task {
                await Logger.shared.debug("📝 Annotation updated: \(annotation.id)")
            }
        }
    }

    func selectAnnotation(_ annotation: ChartAnnotation?) {
        selectedAnnotation = annotation
    }

    func clearAnnotations() {
        annotations.removeAll()
        selectedAnnotation = nil
        Task {
            await Logger.shared.debug("📝 All annotations cleared")
        }
    }
}

// MARK: - Annotation View

struct ChartAnnotationView: View {
    let annotation: ChartAnnotation
    let isSelected: Bool
    let onTap: () -> Void
    let onDelete: () -> Void

    var body: some View {
        VStack(spacing: 4) {
            // Annotation marker
            ZStack {
                Circle()
                    .fill(annotation.color)
                    .frame(width: 12, height: 12)

                if isSelected {
                    Circle()
                        .stroke(Color.white, lineWidth: 2)
                        .frame(width: 16, height: 16)
                }
            }

            // Annotation text
            if !annotation.text.isEmpty {
                Text(annotation.text)
                    .font(.caption)
                    .padding(4)
                    .background(Color.gray.opacity(0.8))
                    .foregroundColor(.white)
                    .cornerRadius(4)
            }
        }
        .position(annotation.position)
        .onTapGesture {
            onTap()
        }
        .contextMenu {
            Button("Edit") {
                onTap()
            }
            Button("Delete", role: .destructive) {
                onDelete()
            }
        }
    }
}

// MARK: - Annotation Editor

struct AnnotationEditorView: View {
    @Binding var annotation: ChartAnnotation
    @Binding var isPresented: Bool

    @State private var editedText: String = ""
    @State private var selectedColor: Color = .blue

    var body: some View {
        VStack(spacing: 16) {
            Text("Edit Annotation")
                .font(.headline)

            TextField("Annotation text", text: $editedText)
                .textFieldStyle(.roundedBorder)

            HStack(spacing: 12) {
                ForEach([Color.blue, .green, .red, .orange, .purple], id: \.self) { color in
                    Circle()
                        .fill(color)
                        .frame(width: 30, height: 30)
                        .overlay(
                            Circle()
                                .stroke(selectedColor == color ? Color.white : Color.clear, lineWidth: 2)
                        )
                        .onTapGesture {
                            selectedColor = color
                        }
                }
            }

            HStack(spacing: 12) {
                Button("Cancel") {
                    isPresented = false
                }
                .keyboardShortcut(.cancelAction)

                Button("Save") {
                    annotation.text = editedText
                    annotation.color = selectedColor
                    isPresented = false
                }
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding()
        .frame(width: 300)
        .onAppear {
            editedText = annotation.text
            selectedColor = annotation.color
        }
    }
}

// MARK: - Annotations Overlay

struct AnnotationsOverlay: View {
    @ObservedObject var annotationManager: AnnotationManager
    @Binding var showEditor: Bool

    var body: some View {
        ZStack {
            ForEach(annotationManager.annotations) { annotation in
                ChartAnnotationView(
                    annotation: annotation,
                    isSelected: annotationManager.selectedAnnotation?.id == annotation.id,
                    onTap: {
                        annotationManager.selectAnnotation(annotation)
                        showEditor = true
                    },
                    onDelete: {
                        annotationManager.removeAnnotation(annotation)
                    }
                )
            }
        }
        .allowsHitTesting(true)
    }
}

// MARK: - Earnings Marker Helper

extension AnnotationManager {
    func addEarningsMarker(at position: CGPoint, symbol: String) {
        let marker = ChartAnnotation(
            type: .earningsMarker,
            position: position,
            text: "📊 \(symbol) Earnings",
            color: .purple
        )
        addAnnotation(marker)
    }
}
