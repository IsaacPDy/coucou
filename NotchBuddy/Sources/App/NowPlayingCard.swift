#if !APPSTORE
import SwiftUI
import AppKit

// MARK: - Now Playing pill (overview right card)

struct NowPlayingPill: View {
    let task: AgentTask
    @Binding var swapping: Bool
    let onTap: () -> Void
    @ObservedObject private var controller = NowPlayingController.shared
    @State private var isHovered = false

    private var showControls: Bool { isHovered && controller.track != nil }

    var body: some View {
        ZStack {
            // Selection target — full pill area, receives taps where controls don't
            Capsule()
                .fill(Color.clear)
                .contentShape(Capsule())
                .onTapGesture { onTap() }

            Capsule()
                .fill(isHovered ? Color(hex: task.color).opacity(0.18) : Color(hex: "#0E0F11"))
                .allowsHitTesting(false)
            Capsule()
                .stroke(Color(hex: task.color).opacity(isHovered ? 0.55 : 0.14), lineWidth: 1)
                .allowsHitTesting(false)

            HStack(spacing: 0) {
                MiniBotCanvasView(task: task, isDancing: controller.isPlaying)
                    .frame(width: 22 / 0.6, height: 22 / 0.6)
                    .frame(width: 22, height: 22, alignment: .center)
                    .padding(.leading, 8)
                Spacer()
            }
            .allowsHitTesting(false)

            Text(task.name)
                .font(.system(size: 10, weight: .semibold))
                .foregroundColor(isHovered ? Color(hex: task.color).lighter(by: 0.3) : Color(hex: "#6B7079"))
                .lineLimit(1)
                .truncationMode(.tail)
                .padding(.leading, 34)
                .padding(.trailing, showControls ? 52 : 10)
                .frame(maxWidth: .infinity, alignment: .center)
                .animation(.spring(response: 0.2, dampingFraction: 0.7), value: showControls)
                .allowsHitTesting(false)

            if showControls {
                HStack(spacing: 0) {
                    Spacer()
                    HStack(spacing: 2) {
                        MusicControlButton(icon: controller.isPlaying ? "pause.fill" : "play.fill", color: task.color) {
                            controller.playPause()
                        }
                        MusicControlButton(icon: "forward.fill", color: task.color) {
                            controller.nextTrack()
                        }
                    }
                    .padding(.trailing, 4)
                }
                .transition(.opacity.combined(with: .scale(scale: 0.85, anchor: .trailing)))
            }
        }
        .frame(maxWidth: .infinity)
        .frame(height: 28)
        .shadow(color: Color(hex: task.color).opacity(isHovered ? 0.35 : 0), radius: 10, x: 0, y: 2)
        .scaleEffect(isHovered ? 1.04 : 1.0)
        .brightness(isHovered ? 0.06 : 0)
        .onHover { newHover in
            guard !swapping else { return }
            withAnimation(.spring(response: 0.2, dampingFraction: 0.7)) { isHovered = newHover }
        }
    }
}

// MARK: - Now Playing card (overview left card)

/// A click anywhere on the card takes me to what's playing (its browser tab, or its app);
/// the playback buttons and the progress bar only do their own thing.
struct NowPlayingCardView: View {
    @ObservedObject private var controller = NowPlayingController.shared
    @State private var hovered = false

    private let accent = Color(hex: NowPlayingController.accent)

    var body: some View {
        Group {
            if let track = controller.track {
                nowPlaying(track)
            } else {
                idleView
            }
        }
        .frame(maxWidth: .infinity, alignment: .topLeading)
        .padding(.top, 4)
    }

    private func nowPlaying(_ track: NowPlayingTrack) -> some View {
        let subtitle = [track.artist, track.album].filter { !$0.isEmpty }.joined(separator: " · ")
        return VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .center, spacing: 9) {
                NowPlayingArtwork(image: controller.artwork ?? appIcon(track), accent: accent)
                    .frame(width: 36, height: 36)

                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 5) {
                        Circle().fill(controller.isPlaying ? accent : Color(hex: "#6B7079"))
                            .frame(width: 6, height: 6)
                        Text(track.title)
                            .font(.system(size: 12, weight: .semibold))
                            .foregroundColor(Color(hex: hovered ? "#FFFFFF" : "#F5F6F8"))
                            .lineLimit(1).truncationMode(.tail)
                    }
                    Text(subtitle.isEmpty ? (track.appName ?? "") : subtitle)
                        .font(.system(size: 11))
                        .foregroundColor(Color(hex: "#8E939C"))
                        .lineLimit(1).truncationMode(.tail)
                }
                Spacer(minLength: 0)
            }
            .padding(.trailing, 24)   // the ↗ button sits top-right
            .padding(.top, 6)

            if track.duration > 0 {
                TimelineView(.animation(minimumInterval: 0.5, paused: !controller.isPlaying)) { context in
                    NowPlayingProgress(
                        position: controller.position(at: context.date),
                        duration: track.duration,
                        accent: accent,
                        canSeek: true,
                        onSeek: { controller.seek(to: $0) }
                    )
                }
                .padding(.top, 7)
            } else {
                Spacer().frame(height: 17)
            }

            controls(track)
                .padding(.top, 4)
        }
        .padding(.leading, 108)
        .padding(.trailing, 12)
        .contentShape(Rectangle())
        .onTapGesture { controller.openSource() }
        .onHover { hovered = $0 }
        .help(track.appName.map { "Open in \($0)" } ?? "Open")
    }

    private func controls(_ track: NowPlayingTrack) -> some View {
        HStack(spacing: 0) {
            HStack(spacing: 10) {
                NowPlayingIconButton(icon: "backward.fill", size: 11, tint: Color(hex: "#C5C8CD"), help: "Previous") {
                    controller.previousTrack()
                }
                Button(action: { controller.playPause() }) {
                    ZStack {
                        Circle().fill(Color(hex: "#F5F6F8"))
                        Image(systemName: controller.isPlaying ? "pause.fill" : "play.fill")
                            .font(.system(size: 8.5, weight: .bold))
                            .foregroundColor(Color(hex: "#0E0F11"))
                            .offset(x: controller.isPlaying ? 0 : 1)
                    }
                    .frame(width: 20, height: 20)
                }
                .buttonStyle(NowPlayingPressStyle())
                .help(controller.isPlaying ? "Pause" : "Play")
                NowPlayingIconButton(icon: "forward.fill", size: 11, tint: Color(hex: "#C5C8CD"), help: "Next") {
                    controller.nextTrack()
                }
            }
            Spacer(minLength: 8)
            // Where a click on the card goes
            if let name = track.appName {
                HStack(spacing: 4) {
                    if let icon = appIcon(track) {
                        Image(nsImage: icon).resizable().frame(width: 12, height: 12)
                    }
                    Text(name)
                        .font(.system(size: 10))
                        .foregroundColor(Color(hex: hovered ? "#C5C8CD" : "#6B7079"))
                        .lineLimit(1)
                    Image(systemName: "arrow.up.right")
                        .font(.system(size: 7, weight: .semibold))
                        .foregroundColor(Color(hex: "#6B7079"))
                        .opacity(hovered ? 1 : 0)
                }
            }
        }
    }

    private func appIcon(_ track: NowPlayingTrack) -> NSImage? {
        guard let id = track.bundleId,
              let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: id) else { return nil }
        return NSWorkspace.shared.icon(forFile: url.path)
    }

    private var idleView: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Circle().fill(accent).frame(width: 7, height: 7)
                Text("Now Playing")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundColor(Color(hex: "#F5F6F8"))
                    .lineLimit(1)
                    .fixedSize()
                Text("Any app or browser")
                    .font(.system(size: 11))
                    .foregroundColor(Color(hex: "#8E939C"))
                    .lineLimit(1)
                    .truncationMode(.tail)
                Spacer(minLength: 2)
            }
            .padding(.top, 6)
            .padding(.trailing, 36)
            HStack(spacing: 5) {
                Circle()
                    .fill(controller.available ? Color(hex: "#6B7079") : Color(hex: "#F4505E"))
                    .frame(width: 5, height: 5)
                Text(controller.available ? "Nothing playing" : "Can't read Now Playing on this Mac")
                    .font(.system(size: 11))
                    .foregroundColor(Color(hex: "#6B7079"))
            }
            .padding(.top, 2)
        }
        .padding(.leading, 108)
        .padding(.trailing, 12)
    }
}
#endif
