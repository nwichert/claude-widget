import AppKit
import Combine
import SwiftUI

/// Borderless floating panel that never takes focus away from the app you are working in.
private final class FloatingPanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}

/// Lets the first click on an inactive panel land on the row instead of being swallowed.
private final class ClickThroughHostingView<Content: View>: NSHostingView<Content> {
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}

final class PanelController: NSObject, NSWindowDelegate {
    private let panel: FloatingPanel
    private let hosting: NSView
    private let layout = PanelLayout()
    private var cancellables = Set<AnyCancellable>()
    private let originKey = "panelTopLeft"
    private let widthKey = "panelWidth"
    private let heightKey = "panelHeight"  // present only once you have chosen a height
    private var liveResizing = false
    private var resizeStart: (height: CGFloat, wasManual: Bool) = (0, false)

    var isVisible: Bool { panel.isVisible }

    init(store: SessionStore, chats: ChatReader, artifacts: ArtifactStore, github: GitHubReader, insights: InsightsStore, activity: ActivityObserver, open: @escaping (SessionRow) -> Void) {
        panel = FloatingPanel(
            contentRect: NSRect(x: 0, y: 0, width: PanelLayout.defaultWidth, height: 120),
            styleMask: [.borderless, .nonactivatingPanel, .resizable],
            backing: .buffered,
            defer: false)
        let defaults = UserDefaults.standard
        let savedWidth = CGFloat(defaults.double(forKey: widthKey))
        if savedWidth >= Self.minSize.width { layout.width = savedWidth }
        let savedHeight = CGFloat(defaults.double(forKey: heightKey))
        layout.manualHeight = savedHeight >= Self.minSize.height

        let host = ClickThroughHostingView(rootView: PanelView(store: store, layout: layout, chats: chats, artifacts: artifacts, github: github, insights: insights, activity: activity, open: open))
        // Report an ideal size for auto-fit, but never pin the window's min/max to it:
        // the window has to stay free to be dragged to any size.
        host.sizingOptions = [.intrinsicContentSize]
        hosting = host
        super.init()

        panel.minSize = Self.minSize
        panel.contentMinSize = Self.minSize

        panel.level = .floating
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        panel.isMovableByWindowBackground = true
        panel.hidesOnDeactivate = false
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.appearance = NSAppearance(named: .vibrantDark)
        panel.contentView = hosting
        panel.delegate = self

        if layout.manualHeight {
            panel.setContentSize(NSSize(width: layout.width, height: savedHeight))
        } else {
            fit()
        }
        restorePosition()
        if layout.minimized { applyMinimized(true) }

        layout.$minimized.dropFirst().removeDuplicates()
            .receive(on: DispatchQueue.main)
            .sink { [weak self] minimized in self?.applyMinimized(minimized) }
            .store(in: &cancellables)

        // Opening settings or hiding a line changes the height too.
        layout.objectWillChange.map { _ in () }
            .merge(with: chats.objectWillChange.map { _ in () })
            .merge(with: artifacts.objectWillChange.map { _ in () })
            .merge(with: github.objectWillChange.map { _ in () })
            .merge(with: insights.objectWillChange.map { _ in () })
            .merge(with: activity.objectWillChange.map { _ in () })
            .merge(with: ModelFit.shared.objectWillChange.map { _ in () })
            .merge(with: Settings.shared.objectWillChange.map { _ in () })
            .receive(on: DispatchQueue.main)
            .sink { [weak self] in
                DispatchQueue.main.async { self?.fit() }
            }
            .store(in: &cancellables)

        // Rows come and go; keep the panel hugging its content with the top edge pinned.
        store.$rows.combineLatest(store.$plan)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                DispatchQueue.main.async { self?.fit() }
            }
            .store(in: &cancellables)
    }

    func show() { panel.orderFrontRegardless() }
    func hide() { panel.orderOut(nil) }
    func toggle() { isVisible ? hide() : show() }

    /// Writes the panel's content to a PNG on a flat dark backdrop (the live blur is not captured).
    func snapshot(to path: String, settings: Bool = false, minimized: Bool? = nil) {
        if let minimized, minimized != layout.minimized {
            let remembered = layout.minimized
            layout.minimized = minimized
            applyMinimized(minimized)
            // A render must not change what the real panel does next launch.
            UserDefaults.standard.set(remembered, forKey: "panelMinimized")
        }
        layout.showSettings = settings
        hosting.layoutSubtreeIfNeeded()
        fit()
        let bounds = hosting.bounds
        guard let rep = hosting.bitmapImageRepForCachingDisplay(in: bounds) else { return }
        hosting.cacheDisplay(in: bounds, to: rep)
        let image = NSImage(size: bounds.size)
        image.lockFocus()
        NSColor(white: 0.13, alpha: 1).setFill()
        NSBezierPath(roundedRect: bounds, xRadius: 14, yRadius: 14).fill()
        rep.draw(in: bounds)
        image.unlockFocus()
        if let tiff = image.tiffRepresentation,
           let png = NSBitmapImageRep(data: tiff)?.representation(using: .png, properties: [:]) {
            try? png.write(to: URL(fileURLWithPath: path))
        }
    }

    private static let minSize = NSSize(width: 260, height: 110)

    /// Collapse to the ticker, or restore the size the panel had before. The top-left corner stays put.
    private func applyMinimized(_ minimized: Bool) {
        let frame = panel.frame
        var size: NSSize
        if minimized {
            panel.styleMask.remove(.resizable)  // a ticker dragged larger would overwrite the saved size
            panel.minSize = PanelLayout.compactSize
            panel.contentMinSize = PanelLayout.compactSize
            size = PanelLayout.compactSize
        } else {
            panel.styleMask.insert(.resizable)
            panel.minSize = Self.minSize
            panel.contentMinSize = Self.minSize
            let savedHeight = CGFloat(UserDefaults.standard.double(forKey: heightKey))
            size = NSSize(width: layout.width,
                          height: layout.manualHeight && savedHeight >= Self.minSize.height ? savedHeight : frame.height)
        }
        panel.setFrame(NSRect(x: frame.minX, y: frame.maxY - size.height, width: size.width, height: size.height),
                       display: true, animate: true)
        panel.invalidateShadow()
        if !minimized { DispatchQueue.main.async { self.fit() } }
    }

    /// Back to the default width with the height hugging the rows.
    func resetSize() {
        UserDefaults.standard.removeObject(forKey: widthKey)
        UserDefaults.standard.removeObject(forKey: heightKey)
        layout.width = PanelLayout.defaultWidth
        layout.manualHeight = false
        DispatchQueue.main.async { self.fit() }
    }

    func windowWillStartLiveResize(_ notification: Notification) {
        guard !layout.minimized else { return }
        liveResizing = true
        resizeStart = (panel.frame.height, layout.manualHeight)
        layout.manualHeight = true  // let the content follow the drag
    }

    /// Keeps the text scale in step with the drag, not only its end.
    func windowDidResize(_ notification: Notification) {
        guard liveResizing, !layout.minimized else { return }
        let width = panel.frame.width
        if abs(layout.width - width) > 0.5 { layout.width = width }
    }

    func windowDidEndLiveResize(_ notification: Notification) {
        guard !layout.minimized else { return }
        liveResizing = false
        let frame = panel.frame
        layout.width = frame.width
        UserDefaults.standard.set(Double(frame.width), forKey: widthKey)
        // A drag that only changed the width leaves the height hugging the rows.
        if !resizeStart.wasManual && abs(frame.height - resizeStart.height) < 6 {
            layout.manualHeight = false
            DispatchQueue.main.async { self.fit() }
        } else {
            UserDefaults.standard.set(Double(frame.height), forKey: heightKey)
        }
        windowDidMove(notification)
    }

    private func fit() {
        guard !layout.manualHeight, !liveResizing, !layout.minimized else { return }
        let size = hosting.fittingSize
        guard size.height > 0 else { return }
        let frame = panel.frame
        guard abs(frame.height - size.height) > 0.5 || abs(frame.width - size.width) > 0.5 else { return }
        panel.setFrame(
            NSRect(x: frame.minX, y: frame.maxY - size.height, width: size.width, height: size.height),
            display: true)
        panel.invalidateShadow()
    }

    private func restorePosition() {
        if let saved = UserDefaults.standard.string(forKey: originKey) {
            let p = NSPointFromString(saved)
            // Only honour a saved spot that is still on a connected display.
            if NSScreen.screens.contains(where: { $0.frame.insetBy(dx: -1, dy: -1).contains(NSPoint(x: p.x + 20, y: p.y - 20)) }) {
                panel.setFrameTopLeftPoint(p)
                return
            }
        }
        if let visible = NSScreen.main?.visibleFrame {
            panel.setFrameTopLeftPoint(NSPoint(x: visible.maxX - panel.frame.width - 16, y: visible.maxY - 16))
        }
    }

    func windowDidMove(_ notification: Notification) {
        let f = panel.frame
        UserDefaults.standard.set(NSStringFromPoint(NSPoint(x: f.minX, y: f.maxY)), forKey: originKey)
    }
}
