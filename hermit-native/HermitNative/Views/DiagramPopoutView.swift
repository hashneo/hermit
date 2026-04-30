import SwiftUI

// MARK: - DiagramPopoutView
//
// A full-screen-capable viewer for a rendered diagram image.
// Supports:
//   • Pinch-to-zoom (iOS) / scroll-wheel zoom (macOS)
//   • Drag to pan (both platforms)
//   • Toolbar buttons for zoom in / out / reset
//   • Double-tap / double-click to reset

struct DiagramPopoutView: View {
    let image: PlatformImage
    /// Optional title shown in the toolbar / window title bar.
    var title: String = "Diagram"
    /// Called when the user dismisses the view (sheet/window close button).
    var onDismiss: (() -> Void)? = nil

    @State private var scale: CGFloat = 1.0
    @State private var offset: CGSize = .zero

    // Gesture accumulators
    @State private var lastScale: CGFloat = 1.0
    @State private var lastOffset: CGSize = .zero

    private let minScale: CGFloat = 0.25
    private let maxScale: CGFloat = 8.0
    private let scaleStep: CGFloat = 0.5

    var body: some View {
        ZStack(alignment: .topTrailing) {
            // Background
            Color(white: 0.12)
                .ignoresSafeArea()

            // Diagram image
            GeometryReader { geo in
                platformImage
                    .resizable()
                    .scaledToFit()
                    .scaleEffect(scale)
                    .offset(offset)
                    .frame(width: geo.size.width, height: geo.size.height)
                    .contentShape(Rectangle())
                    // Pan gesture
                    .gesture(
                        DragGesture()
                            .onChanged { v in
                                offset = CGSize(
                                    width:  lastOffset.width  + v.translation.width,
                                    height: lastOffset.height + v.translation.height
                                )
                            }
                            .onEnded { _ in lastOffset = offset }
                    )
                    // Pinch-to-zoom (iOS) / trackpad magnify (macOS)
                    .gesture(
                        MagnificationGesture()
                            .onChanged { v in
                                scale = (lastScale * v).clamped(to: minScale...maxScale)
                            }
                            .onEnded { _ in lastScale = scale }
                    )
                    // Double-tap / double-click to reset
                    .onTapGesture(count: 2) {
                        withAnimation(.spring()) { reset() }
                    }
            }

            // Toolbar overlay
            toolbar
        }
        .navigationTitle(title)
    }

    // MARK: - Toolbar

    private var toolbar: some View {
        HStack(spacing: 8) {
            toolbarButton(systemImage: "minus.magnifyingglass") {
                withAnimation { scale = (scale - scaleStep).clamped(to: minScale...maxScale)
                    lastScale = scale }
            }
            toolbarButton(systemImage: "arrow.up.left.and.down.right.magnifyingglass") {
                withAnimation(.spring()) { reset() }
            }
            toolbarButton(systemImage: "plus.magnifyingglass") {
                withAnimation { scale = (scale + scaleStep).clamped(to: minScale...maxScale)
                    lastScale = scale }
            }
            if let dismiss = onDismiss {
                Divider().frame(height: 20).foregroundStyle(.white.opacity(0.3))
                toolbarButton(systemImage: "xmark") { dismiss() }
            }
        }
        .padding(8)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 10))
        .padding(12)
    }

    private func toolbarButton(systemImage: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: systemImage)
                .font(.system(size: 15, weight: .medium))
                .foregroundStyle(.white)
                .frame(width: 30, height: 30)
        }
        .buttonStyle(.plain)
    }

    // MARK: - Platform image

    private var platformImage: Image {
#if os(macOS)
        Image(nsImage: image)
#else
        Image(uiImage: image)
#endif
    }

    // MARK: - Helpers

    private func reset() {
        scale = 1.0
        lastScale = 1.0
        offset = .zero
        lastOffset = .zero
    }
}

private extension Comparable {
    func clamped(to range: ClosedRange<Self>) -> Self {
        min(max(self, range.lowerBound), range.upperBound)
    }
}

// MARK: - macOS floating window manager

#if os(macOS)
@MainActor
final class DiagramWindowManager {
    static let shared = DiagramWindowManager()
    /// Keyed by diagram source hash so each unique diagram gets one window.
    private var controllers: [Int: NSWindowController] = [:]

    func open(image: PlatformImage, title: String) {
        let key = ObjectIdentifier(image).hashValue
        if let existing = controllers[key] {
            existing.window?.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }

        let view = DiagramPopoutView(image: image, title: title) { [weak self] in
            self?.controllers[key]?.window?.close()
            self?.controllers.removeValue(forKey: key)
        }

        let hosting = NSHostingController(rootView: view)
        let window = NSWindow(contentViewController: hosting)
        window.title = title
        window.styleMask = [.titled, .closable, .resizable, .miniaturizable]
        let screenSize = NSScreen.main?.visibleFrame.size ?? NSSize(width: 1440, height: 900)
        window.setContentSize(NSSize(width: screenSize.width * 0.6, height: screenSize.height * 0.7))
        window.center()
        window.isReleasedWhenClosed = false
        window.backgroundColor = NSColor(white: 0.12, alpha: 1)

        let wc = NSWindowController(window: window)
        controllers[key] = wc
        wc.showWindow(nil)
        NSApp.activate(ignoringOtherApps: true)
    }
}
#endif
