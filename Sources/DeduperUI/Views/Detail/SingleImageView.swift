import SwiftUI
import AppKit

/// Single-member image view with pinch-to-zoom and pan.
/// Used in single-mode comparison as an alternative to the
/// side-by-side slider.
public struct SingleImageView: View {
    public let member: MemberDetail

    @State private var image: NSImage?
    @State private var magnification: CGFloat = 1.0
    @State private var lastMagnification: CGFloat = 1.0
    @State private var offset: CGSize = .zero
    @State private var lastOffset: CGSize = .zero
    @State private var showQuickLook = false

    private let minZoom: CGFloat = 1.0
    private let maxZoom: CGFloat = 8.0

    public init(member: MemberDetail) {
        self.member = member
    }

    public var body: some View {
        GeometryReader { geo in
            ZStack {
                Color.black.opacity(0.05)

                if let image {
                    Image(nsImage: image)
                        .resizable()
                        .aspectRatio(contentMode: .fit)
                        .scaleEffect(magnification)
                        .offset(offset)
                        .gesture(
                            MagnifyGesture()
                                .onChanged { value in
                                    let raw = lastMagnification
                                        * value.magnification
                                    magnification = max(
                                        minZoom,
                                        min(maxZoom, raw)
                                    )
                                }
                                .onEnded { _ in
                                    lastMagnification = magnification
                                    if magnification <= minZoom {
                                        withAnimation(.spring) {
                                            offset = .zero
                                            lastOffset = .zero
                                        }
                                    }
                                }
                        )
                        .simultaneousGesture(
                            DragGesture()
                                .onChanged { value in
                                    guard magnification > 1 else {
                                        return
                                    }
                                    offset = CGSize(
                                        width: lastOffset.width
                                            + value.translation.width,
                                        height: lastOffset.height
                                            + value.translation.height
                                    )
                                }
                                .onEnded { _ in
                                    lastOffset = offset
                                }
                        )
                        .onTapGesture(count: 2) {
                            withAnimation(.spring) {
                                if magnification > minZoom {
                                    magnification = minZoom
                                    lastMagnification = minZoom
                                    offset = .zero
                                    lastOffset = .zero
                                } else {
                                    magnification = 3.0
                                    lastMagnification = 3.0
                                }
                            }
                        }
                } else if !member.fileExists {
                    Label(
                        "File Missing",
                        systemImage: "questionmark.folder"
                    )
                    .foregroundStyle(.secondary)
                } else {
                    ProgressView()
                }
            }
            .overlay(alignment: .bottomTrailing) {
                zoomControls
                    .padding(8)
            }
            .overlay(alignment: .topLeading) {
                imageLabel(member.fileName)
                    .padding(8)
            }
            .clipShape(RoundedRectangle(cornerRadius: 8))
        }
        .popover(isPresented: $showQuickLook) {
            QuickLookPreview(
                url: URL(fileURLWithPath: member.path)
            )
            .frame(width: 800, height: 800)
        }
        .task(id: member.path) {
            await loadImage()
        }
        .onChange(of: member.path) {
            magnification = minZoom
            lastMagnification = minZoom
            offset = .zero
            lastOffset = .zero
        }
    }

    private var zoomControls: some View {
        HStack(spacing: 4) {
            Button {
                withAnimation(.spring) {
                    magnification = max(
                        minZoom, magnification - 0.5
                    )
                    lastMagnification = magnification
                    if magnification <= minZoom {
                        offset = .zero
                        lastOffset = .zero
                    }
                }
            } label: {
                Image(systemName: "minus.magnifyingglass")
            }
            .disabled(magnification <= minZoom)

            Text("\(Int(magnification * 100))%")
                .font(.caption2.monospacedDigit())
                .frame(width: 36)

            Button {
                withAnimation(.spring) {
                    magnification = min(
                        maxZoom, magnification + 0.5
                    )
                    lastMagnification = magnification
                }
            } label: {
                Image(systemName: "plus.magnifyingglass")
            }
            .disabled(magnification >= maxZoom)

            Button {
                withAnimation(.spring) {
                    magnification = minZoom
                    lastMagnification = minZoom
                    offset = .zero
                    lastOffset = .zero
                }
            } label: {
                Image(systemName: "arrow.counterclockwise")
            }
            .disabled(
                magnification == minZoom && offset == .zero
            )

            if member.fileExists {
                Button {
                    showQuickLook = true
                } label: {
                    Image(systemName: "eye")
                }
                .help("Quick Look")
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .background(.ultraThinMaterial)
        .clipShape(Capsule())
        .buttonStyle(.plain)
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

    private func loadImage() async {
        image = DownsampledImageLoader.load(
            url: URL(fileURLWithPath: member.path),
            maxPixelSize: 1200
        )
    }
}
