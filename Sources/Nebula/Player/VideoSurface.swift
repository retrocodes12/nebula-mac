import SwiftUI
import AppKit

/// Hosts the engine's Metal layer and keeps its drawable the size of the view in real pixels.
final class VideoHostView: NSView {
    let metal: MetalLayer

    init(layer: MetalLayer) {
        metal = layer
        super.init(frame: .zero)
        layer.backgroundColor = NSColor.black.cgColor
        layer.framebufferOnly = true
        wantsLayer = true                     // asks makeBackingLayer for the Metal layer
        autoresizingMask = [.width, .height]
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    override func makeBackingLayer() -> CALayer { metal }

    override func layout() {
        super.layout()
        fit()
    }

    override func viewDidChangeBackingProperties() {
        super.viewDidChangeBackingProperties()
        fit()
    }

    private func fit() {
        let scale = window?.screen?.backingScaleFactor ?? NSScreen.main?.backingScaleFactor ?? 2
        metal.contentsScale = scale
        metal.drawableSize = CGSize(width: bounds.width * scale, height: bounds.height * scale)
    }
}

struct VideoSurface: NSViewRepresentable {
    let controller: MPVController

    func makeNSView(context: Context) -> VideoHostView { VideoHostView(layer: controller.layer) }
    func updateNSView(_ nsView: VideoHostView, context: Context) {}
}
