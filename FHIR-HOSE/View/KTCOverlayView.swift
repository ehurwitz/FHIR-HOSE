//
//  KTCOverlayView.swift
//  FHIR-HOSE
//
//  Created by Claude Code on 1/27/26.
//

import SwiftUI

/// Displays the scanned image with bounding-box overlays for detected fields.
struct KTCOverlayView: View {
    let image: UIImage
    let fields: [KTCField]
    let showLabelBoxes: Bool

    var body: some View {
        GeometryReader { geo in
            let fittedRect = Self.aspectFitRect(
                imageSize: image.size,
                containerSize: geo.size
            )

            Image(uiImage: image)
                .resizable()
                .scaledToFit()
                .frame(width: geo.size.width, height: geo.size.height)
                .overlay(alignment: .topLeading) {
                    ForEach(fields) { field in
                        let rect = Self.visionToSwiftUI(
                            visionBox: field.labelBoundingBox,
                            fittedRect: fittedRect
                        )

                        // Label box outline
                        if showLabelBoxes {
                            Rectangle()
                                .stroke(Color.indigo, lineWidth: 1.5)
                                .frame(width: rect.width, height: rect.height)
                                .position(x: rect.midX, y: rect.midY)
                        }

                        // Value badge (positioned to the right of the label box)
                        if !field.value.isEmpty {
                            Text(field.value)
                                .font(.system(size: max(10, min(14, rect.height * 0.7))))
                                .foregroundColor(.white)
                                .padding(.horizontal, 4)
                                .padding(.vertical, 2)
                                .background(Color.indigo.opacity(0.85))
                                .cornerRadius(4)
                                .position(
                                    x: min(rect.maxX + 4 + badgeWidth(field.value, height: rect.height) / 2,
                                           fittedRect.maxX - 4),
                                    y: rect.midY
                                )
                        }
                    }
                }
        }
    }

    // MARK: - Coordinate Conversion

    /// Compute the rect where an image is displayed within a container using aspectFit.
    static func aspectFitRect(imageSize: CGSize, containerSize: CGSize) -> CGRect {
        guard imageSize.width > 0, imageSize.height > 0 else {
            return CGRect(origin: .zero, size: containerSize)
        }
        let scaleX = containerSize.width / imageSize.width
        let scaleY = containerSize.height / imageSize.height
        let scale = min(scaleX, scaleY)

        let displayW = imageSize.width * scale
        let displayH = imageSize.height * scale
        let offsetX = (containerSize.width - displayW) / 2
        let offsetY = (containerSize.height - displayH) / 2

        return CGRect(x: offsetX, y: offsetY, width: displayW, height: displayH)
    }

    /// Convert a Vision boundingBox (normalized, origin bottom-left)
    /// to a SwiftUI rect (points, origin top-left) within the fitted image area.
    static func visionToSwiftUI(visionBox: CGRect, fittedRect: CGRect) -> CGRect {
        let x = fittedRect.origin.x + visionBox.origin.x * fittedRect.width
        let y = fittedRect.origin.y + (1.0 - visionBox.origin.y - visionBox.height) * fittedRect.height
        let w = visionBox.width * fittedRect.width
        let h = visionBox.height * fittedRect.height
        return CGRect(x: x, y: y, width: w, height: h)
    }

    /// Rough estimate of badge width for positioning.
    private func badgeWidth(_ text: String, height: CGFloat) -> CGFloat {
        let fontSize = max(10, min(14, height * 0.7))
        return CGFloat(text.count) * fontSize * 0.6 + 8
    }
}

// MARK: - Expanded Image Sheet

/// Full-screen view for inspecting the overlay in detail.
struct KTCExpandedImageView: View {
    let image: UIImage
    let fields: [KTCField]
    @Binding var showLabelBoxes: Bool
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationView {
            VStack(spacing: 0) {
                KTCOverlayView(
                    image: image,
                    fields: fields,
                    showLabelBoxes: showLabelBoxes
                )

                // Bottom bar with toggle
                HStack {
                    Toggle("Show label boxes", isOn: $showLabelBoxes)
                        .font(.subheadline)
                }
                .padding()
                .background(Color(.systemBackground))
            }
            .navigationTitle("Scan Preview")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Done") { dismiss() }
                }
            }
        }
    }
}
