import SwiftUI
import AppKit

/// Interactive split-image comparison with a draggable vertical divider.
/// Keeper image on the left (masked to divider position),
/// comparison image on the right (full frame behind).
public struct SplitImageComparison: View {
    public let keeperPath: String
    public let comparisonPath: String
    public let keeperLabel: String
    public let comparisonLabel: String

    @State private var dividerFraction: CGFloat = 0.5
    @State private var keeperImage: NSImage?
    @State private var comparisonImage: NSImage?

    public init(
        keeperPath: String,
        comparisonPath: String,
        keeperLabel: String,
        comparisonLabel: String
    ) {
        self.keeperPath = keeperPath
        self.comparisonPath = comparisonPath
        self.keeperLabel = keeperLabel
        self.comparisonLabel = comparisonLabel
    }

    public var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                // Comparison image (full frame, underneath)
                imageLayer(comparisonImage, size: geo.size)

                // Keeper image (clipped to divider fraction)
                imageLayer(keeperImage, size: geo.size)
                    .mask(
                        HStack(spacing: 0) {
                            Rectangle()
                                .frame(
                                    width: geo.size.width
                                        * dividerFraction
                                )
                            Spacer(minLength: 0)
                        }
                    )

                // Divider handle
                dividerOverlay(geo: geo)

                // Labels
                labelsOverlay(geo: geo)
            }
            .clipped()
        }
        .background(Color.black.opacity(0.05))
        .clipShape(RoundedRectangle(cornerRadius: 8))
        .task(id: keeperPath + comparisonPath) {
            await loadImages()
        }
    }

    @ViewBuilder
    private func imageLayer(
        _ image: NSImage?,
        size: CGSize
    ) -> some View {
        if let image {
            Image(nsImage: image)
                .resizable()
                .aspectRatio(contentMode: .fit)
                .frame(
                    width: size.width,
                    height: size.height
                )
        } else {
            Color.gray.opacity(0.1)
                .frame(
                    width: size.width,
                    height: size.height
                )
        }
    }

    private func dividerOverlay(
        geo: GeometryProxy
    ) -> some View {
        let xPos = geo.size.width * dividerFraction
        return ZStack {
            // Vertical line
            Rectangle()
                .fill(.white)
                .frame(width: 3, height: geo.size.height)
                .shadow(color: .black.opacity(0.3), radius: 2)

            // Drag handle
            Circle()
                .fill(.white)
                .frame(width: 28, height: 28)
                .shadow(color: .black.opacity(0.3), radius: 3)
                .overlay {
                    Image(
                        systemName: "line.3.horizontal"
                    )
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                }
        }
        .position(
            x: xPos,
            y: geo.size.height / 2
        )
        .gesture(
            DragGesture()
                .onChanged { value in
                    let fraction =
                        value.location.x / geo.size.width
                    dividerFraction = max(
                        0.05, min(0.95, fraction)
                    )
                }
        )
    }

    private func labelsOverlay(
        geo: GeometryProxy
    ) -> some View {
        VStack {
            HStack {
                imageLabel(keeperLabel)
                Spacer()
                imageLabel(comparisonLabel)
            }
            .padding(8)
            Spacer()
        }
    }

    private func imageLabel(_ text: String) -> some View {
        Text(text)
            .font(.caption.bold())
            .padding(.horizontal, 6)
            .padding(.vertical, 3)
            .background(.black.opacity(0.6))
            .foregroundStyle(.white)
            .clipShape(RoundedRectangle(cornerRadius: 4))
    }

    private func loadImages() async {
        let maxSize: CGFloat = 1200
        keeperImage = DownsampledImageLoader.load(
            url: URL(fileURLWithPath: keeperPath),
            maxPixelSize: maxSize
        )
        comparisonImage = DownsampledImageLoader.load(
            url: URL(fileURLWithPath: comparisonPath),
            maxPixelSize: maxSize
        )
    }
}
