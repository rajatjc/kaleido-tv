import AVKit
import SwiftUI

#if os(macOS)

/// The system player view: AirPlay, Picture in Picture and full screen come with it.
struct VideoView: NSViewRepresentable {
    let playback: PlaybackController
    let gravity: AVLayerVideoGravity

    func makeCoordinator() -> Coordinator { Coordinator(playback: playback) }

    func makeNSView(context: Context) -> AVPlayerView {
        let view = AVPlayerView()
        view.player = playback.player
        view.controlsStyle = .floating
        view.showsFullScreenToggleButton = true
        view.allowsPictureInPicturePlayback = true
        view.videoGravity = gravity
        view.pictureInPictureDelegate = context.coordinator
        return view
    }

    func updateNSView(_ view: AVPlayerView, context: Context) {
        if view.videoGravity != gravity { view.videoGravity = gravity }
    }

    @MainActor
    final class Coordinator: NSObject, @preconcurrency AVPlayerViewPictureInPictureDelegate {
        let playback: PlaybackController

        init(playback: PlaybackController) { self.playback = playback }

        func playerViewDidStartPicture(inPicture playerView: AVPlayerView) {
            playback.pipActive = true
        }

        func playerViewDidStopPicture(inPicture playerView: AVPlayerView) {
            playback.pipActive = false
        }

        func playerView(_ playerView: AVPlayerView,
                        restoreUserInterfaceForPictureInPictureStopWithCompletionHandler completion: @escaping (Bool) -> Void) {
            completion(true)
        }
    }
}

#else

/// The system player view: AirPlay, Picture in Picture, full screen and lock-screen controls come with it.
struct VideoView: UIViewControllerRepresentable {
    let playback: PlaybackController
    let gravity: AVLayerVideoGravity

    func makeCoordinator() -> Coordinator { Coordinator(playback: playback) }

    func makeUIViewController(context: Context) -> AVPlayerViewController {
        let vc = AVPlayerViewController()
        vc.player = playback.player
        vc.allowsPictureInPicturePlayback = true
        vc.canStartPictureInPictureAutomaticallyFromInline = true
        vc.videoGravity = gravity
        vc.delegate = context.coordinator
        return vc
    }

    func updateUIViewController(_ vc: AVPlayerViewController, context: Context) {
        if vc.videoGravity != gravity { vc.videoGravity = gravity }
    }

    @MainActor
    final class Coordinator: NSObject, @preconcurrency AVPlayerViewControllerDelegate {
        let playback: PlaybackController

        init(playback: PlaybackController) { self.playback = playback }

        func playerViewControllerDidStartPictureInPicture(_ vc: AVPlayerViewController) {
            playback.pipActive = true
        }

        func playerViewControllerDidStopPictureInPicture(_ vc: AVPlayerViewController) {
            playback.pipActive = false
        }

        func playerViewController(
            _ vc: AVPlayerViewController,
            restoreUserInterfaceForPictureInPictureStopWithCompletionHandler completion: @escaping (Bool) -> Void
        ) {
            completion(true)
        }
    }
}

#endif
