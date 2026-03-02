import SwiftUI
import AVKit

/// Split-panel video comparison with synchronized playback.
/// Keeper video on the left (masked), comparison video on the right.
/// Audio crossfades as the divider moves: whichever side is dominant
/// (>50%) plays at full volume; the other fades to silence.
public struct SplitVideoComparison: View {
    public let keeperPath: String
    public let comparisonPath: String
    public let keeperLabel: String
    public let comparisonLabel: String

    @State private var dividerFraction: CGFloat = 0.5
    @State private var keeperPlayer: AVPlayer?
    @State private var comparisonPlayer: AVPlayer?

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
                // Comparison video (full frame, underneath)
                if let player = comparisonPlayer {
                    VideoPlayer(player: player)
                        .frame(
                            width: geo.size.width,
                            height: geo.size.height
                        )
                        .disabled(true)
                }

                // Keeper video (masked to divider fraction)
                if let player = keeperPlayer {
                    VideoPlayer(player: player)
                        .frame(
                            width: geo.size.width,
                            height: geo.size.height
                        )
                        .disabled(true)
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
                }

                // Divider handle (same as SplitImageComparison)
                dividerOverlay(geo: geo)

                // Labels
                labelsOverlay

                // Play/Pause controls
                playbackControls
                    .padding(8)
            }
            .clipped()
        }
        .background(Color.black)
        .clipShape(RoundedRectangle(cornerRadius: 8))
        .task(id: keeperPath + comparisonPath) {
            await setupPlayers()
        }
        .onChange(of: dividerFraction) {
            updateVolumes()
        }
        .onDisappear {
            keeperPlayer?.pause()
            comparisonPlayer?.pause()
        }
    }

    private func dividerOverlay(
        geo: GeometryProxy
    ) -> some View {
        let xPos = geo.size.width * dividerFraction
        return ZStack {
            Rectangle()
                .fill(.white)
                .frame(width: 3, height: geo.size.height)
                .shadow(color: .black.opacity(0.3), radius: 2)

            Circle()
                .fill(.white)
                .frame(width: 28, height: 28)
                .shadow(color: .black.opacity(0.3), radius: 3)
                .overlay {
                    Image(systemName: "line.3.horizontal")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
        }
        .position(
            x: xPos, y: geo.size.height / 2
        )
        .gesture(
            DragGesture()
                .onChanged { value in
                    let fraction = value.location.x
                        / max(1, geo.size.width)
                    dividerFraction = max(
                        0.05, min(0.95, fraction)
                    )
                }
        )
    }

    private var labelsOverlay: some View {
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

    private var playbackControls: some View {
        VStack {
            Spacer()
            HStack(spacing: 12) {
                Spacer()
                Button {
                    togglePlayback()
                } label: {
                    Image(
                        systemName: isPlaying
                            ? "pause.circle.fill"
                            : "play.circle.fill"
                    )
                    .font(.title)
                    .foregroundStyle(.white)
                    .shadow(radius: 2)
                }
                .buttonStyle(.plain)

                Button {
                    seekToStart()
                } label: {
                    Image(
                        systemName: "backward.end.circle.fill"
                    )
                    .font(.title)
                    .foregroundStyle(.white)
                    .shadow(radius: 2)
                }
                .buttonStyle(.plain)
                Spacer()
            }
            .padding(.bottom, 8)
        }
    }

    private var isPlaying: Bool {
        (keeperPlayer?.timeControlStatus == .playing)
            || (comparisonPlayer?.timeControlStatus == .playing)
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

    private func setupPlayers() async {
        keeperPlayer?.pause()
        comparisonPlayer?.pause()

        let k = AVPlayer(
            url: URL(fileURLWithPath: keeperPath)
        )
        let c = AVPlayer(
            url: URL(fileURLWithPath: comparisonPath)
        )

        // Loop both players
        NotificationCenter.default.addObserver(
            forName: .AVPlayerItemDidPlayToEndTime,
            object: k.currentItem,
            queue: .main
        ) { _ in k.seek(to: .zero); k.play() }
        NotificationCenter.default.addObserver(
            forName: .AVPlayerItemDidPlayToEndTime,
            object: c.currentItem,
            queue: .main
        ) { _ in c.seek(to: .zero); c.play() }

        keeperPlayer = k
        comparisonPlayer = c
        updateVolumes()

        k.play()
        c.play()
    }

    private func updateVolumes() {
        // Keeper is dominant when left side > 50%
        let keeperDominant = dividerFraction >= 0.5
        keeperPlayer?.volume = keeperDominant ? 1.0 : 0.0
        comparisonPlayer?.volume = keeperDominant ? 0.0 : 1.0
    }

    private func togglePlayback() {
        guard let k = keeperPlayer,
              let c = comparisonPlayer else { return }
        if isPlaying {
            k.pause()
            c.pause()
        } else {
            // Sync to same time before resuming
            let time = k.currentTime()
            c.seek(to: time)
            k.play()
            c.play()
        }
    }

    private func seekToStart() {
        keeperPlayer?.seek(to: .zero)
        comparisonPlayer?.seek(to: .zero)
    }
}
