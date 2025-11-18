//
//  ChartAnnotationViews.swift
//  Stockbar
//
//  Views for displaying and editing chart annotations.
//

import SwiftUI
import Charts

// MARK: - Annotation Editor
struct AnnotationEditorView: View {
    @Binding var annotation: ChartAnnotation
    @Binding var isPresented: Bool
    
    @State private var text: String = ""
    @State private var colorHex: String = "#0000FF"
    @State private var type: ChartAnnotation.AnnotationType = .text
    
    var body: some View {
        VStack(spacing: 20) {
            Text("Edit Annotation")
                .font(.headline)
            
            Picker("Type", selection: $type) {
                Text("Text").tag(ChartAnnotation.AnnotationType.text)
                Text("Note").tag(ChartAnnotation.AnnotationType.note)
                Text("Buy").tag(ChartAnnotation.AnnotationType.buyMarker)
                Text("Sell").tag(ChartAnnotation.AnnotationType.sellMarker)
            }
            .pickerStyle(.segmented)
            
            TextField("Annotation Text", text: $text)
                .textFieldStyle(.roundedBorder)
            
            ColorPicker("Color", selection: Binding(
                get: { Color(hex: colorHex) ?? .blue },
                set: { colorHex = $0.toHex() ?? "#0000FF" }
            ))
            
            HStack {
                Button("Cancel") {
                    isPresented = false
                }
                .keyboardShortcut(.cancelAction)
                
                Button("Save") {
                    // Update the annotation with new values
                    // Since annotation is a struct (value type) and passed via binding,
                    // we need to create a new one or update the binding.
                    // But ChartAnnotation properties are let.
                    let updated = ChartAnnotation(
                        id: annotation.id,
                        type: type,
                        date: annotation.date,
                        price: annotation.price,
                        text: text,
                        symbol: annotation.symbol,
                        colorHex: colorHex
                    )
                    annotation = updated
                    isPresented = false
                }
                .keyboardShortcut(.defaultAction)
                .disabled(text.isEmpty)
            }
        }
        .padding()
        .frame(width: 300)
        .onAppear {
            text = annotation.text
            colorHex = annotation.colorHex
            type = annotation.type
        }
    }
}

