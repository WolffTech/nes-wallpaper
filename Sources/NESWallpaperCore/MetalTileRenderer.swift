// SPDX-FileCopyrightText: 2026 Nick Wolff <nick@wolff.tech>
// SPDX-License-Identifier: GPL-2.0-only

import AppKit
import Metal
import QuartzCore

// Metal compositing for the wallpaper grid: one CAMetalLayer per desktop
// window, one texture per tile uploaded straight from the helper's shared
// memory, drawn as aspect-fit quads in a single render pass per frame.

/// The shader is embedded as a string and compiled at startup: SwiftPM
/// resource bundles would complicate Scripts/make-app.sh (which ships bare
/// binaries), and the source is ~30 lines.
private let shaderSource = """
#include <metal_stdlib>
using namespace metal;

struct VOut { float4 pos [[position]]; float2 uv; };

vertex VOut tileVertex(uint vid [[vertex_id]],
                       constant float4 &rect [[buffer(0)]]) { // NDC x,y,w,h
    float2 unit = float2(vid & 1, vid >> 1); // strip: (0,0)(1,0)(0,1)(1,1)
    VOut o;
    o.pos = float4(rect.x + unit.x * rect.z, rect.y + unit.y * rect.w, 0, 1);
    o.uv  = float2(unit.x, 1.0 - unit.y);    // flip: shm rows are top-down
    return o;
}

fragment float4 tileFragment(VOut in [[stage_in]],
                             texture2d<float> tex [[texture(0)]],
                             sampler s [[sampler(0)]],
                             constant float &brightness [[buffer(0)]]) {
    // Force opaque: the NTSC filter writes 0 into the X byte.
    return float4(tex.sample(s, in.uv).rgb * brightness, 1.0);
}
"""

/// Device, queue, pipeline, and sampler shared by every window's renderer.
public final class MetalContext {
    public let device: MTLDevice
    let queue: MTLCommandQueue
    let pipeline: MTLRenderPipelineState
    let sampler: MTLSamplerState

    public init() throws {
        guard let device = MTLCreateSystemDefaultDevice() else {
            throw WallpaperError("no Metal device available")
        }
        guard let queue = device.makeCommandQueue() else {
            throw WallpaperError("failed to create Metal command queue")
        }
        self.device = device
        self.queue = queue

        let library: MTLLibrary
        do {
            library = try device.makeLibrary(source: shaderSource, options: nil)
        } catch {
            throw WallpaperError("failed to compile shaders: \(error)")
        }
        let descriptor = MTLRenderPipelineDescriptor()
        descriptor.vertexFunction = library.makeFunction(name: "tileVertex")
        descriptor.fragmentFunction = library.makeFunction(name: "tileFragment")
        descriptor.colorAttachments[0].pixelFormat = .bgra8Unorm
        do {
            pipeline = try device.makeRenderPipelineState(descriptor: descriptor)
        } catch {
            throw WallpaperError("failed to create render pipeline: \(error)")
        }

        let samplerDescriptor = MTLSamplerDescriptor()
        // Nearest when a cell is larger than the frame (crisp NES pixels),
        // linear when smaller (filtered frames often exceed the cell).
        samplerDescriptor.magFilter = .nearest
        samplerDescriptor.minFilter = .linear
        samplerDescriptor.sAddressMode = .clampToEdge
        samplerDescriptor.tAddressMode = .clampToEdge
        guard let sampler = device.makeSamplerState(descriptor: samplerDescriptor) else {
            throw WallpaperError("failed to create sampler state")
        }
        self.sampler = sampler
    }
}

/// Layer-hosting view whose backing layer is a CAMetalLayer sized in device
/// pixels — setting contentsScale/drawableSize here is what makes tiles
/// Retina-sharp (the old CALayer path never set contentsScale).
public final class WallpaperMetalView: NSView {
    private let device: MTLDevice
    public var lowPowerMode: Bool {
        didSet {
            guard lowPowerMode != oldValue else { return }
            updateDrawableSize()
        }
    }

    public init(frame: NSRect, device: MTLDevice, lowPowerMode: Bool = false) {
        self.device = device
        self.lowPowerMode = lowPowerMode
        super.init(frame: frame)
        wantsLayer = true
    }

    public required init?(coder: NSCoder) { fatalError("not used") }

    var metalLayer: CAMetalLayer { layer as! CAMetalLayer }

    public override func makeBackingLayer() -> CALayer {
        let layer = CAMetalLayer()
        layer.device = device
        layer.pixelFormat = .bgra8Unorm
        layer.framebufferOnly = true
        layer.isOpaque = true
        layer.backgroundColor = NSColor.black.cgColor
        return layer
    }

    public override func layout() {
        super.layout()
        updateDrawableSize()
    }

    public override func viewDidChangeBackingProperties() {
        super.viewDidChangeBackingProperties()
        updateDrawableSize()
    }

    private func updateDrawableSize() {
        // Logical-resolution rendering is a substantial bandwidth and GPU
        // saving on Retina laptops, while still leaving far more pixels than
        // the source NES tiles contain.
        let scale = lowPowerMode ? 1.0 : (window?.backingScaleFactor ?? 2.0)
        metalLayer.contentsScale = scale
        let size = CGSize(width: bounds.width * scale, height: bounds.height * scale)
        if size.width > 0, size.height > 0, metalLayer.drawableSize != size {
            metalLayer.drawableSize = size
        }
    }
}

/// Renders one window's columns x rows grid. Textures are keyed by tile
/// slot index (rotation replaces the TileProcess in a slot, never the
/// texture: the filter — and therefore the frame size — is fixed per run).
public final class TileGridRenderer {
    private let context: MetalContext
    private let metalLayer: CAMetalLayer
    private let columns: Int
    private let rows: Int
    private let textures: [MTLTexture]
    private var lastUploaded: [UInt32?]
    private var lastDrawnSize = CGSize.zero
    private var needsPresent = false

    /// Visual emphasis for tile selection and live play.
    public enum Emphasis: Equatable {
        /// Normal wallpaper: every tile at full brightness.
        case none
        /// Dim every tile except this one (by controller tile index);
        /// nil dims the whole grid, e.g. selection mode with no hover.
        case spotlight(Int?)
    }

    public var emphasis: Emphasis = .none {
        didSet { needsPresent = needsPresent || emphasis != oldValue }
    }

    /// When set, this window draws only that tile (controller index),
    /// aspect-fit to the whole drawable at full brightness; nil restores
    /// the grid. Emphasis is ignored while set.
    public var fullscreenTile: Int? {
        didSet { needsPresent = needsPresent || fullscreenTile != oldValue }
    }

    public init(context: MetalContext, view: WallpaperMetalView,
         columns: Int, rows: Int, tileWidth: Int, tileHeight: Int) throws {
        self.context = context
        self.metalLayer = view.metalLayer
        self.columns = columns
        self.rows = rows

        let descriptor = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .bgra8Unorm, width: tileWidth, height: tileHeight,
            mipmapped: false)
        descriptor.usage = .shaderRead
        var textures: [MTLTexture] = []
        for _ in 0..<(columns * rows) {
            guard let texture = context.device.makeTexture(descriptor: descriptor) else {
                throw WallpaperError("failed to allocate tile texture")
            }
            textures.append(texture)
        }
        self.textures = textures
        self.lastUploaded = Array(repeating: nil, count: columns * rows)
    }

    /// Rotation swapped the helper in this slot: the new process restarts
    /// frame_count, which could coincidentally match the old value, so force
    /// the next draw to re-upload.
    public func invalidateTile(_ localIndex: Int) {
        guard lastUploaded.indices.contains(localIndex) else { return }
        lastUploaded[localIndex] = nil
    }

    /// Aspect-fit a texture centered in `cell`, both in drawable pixels.
    public static func aspectFitRect(textureWidth: Int, textureHeight: Int,
                                     in cell: CGRect) -> CGRect {
        let scale = min(cell.width / CGFloat(textureWidth),
                        cell.height / CGFloat(textureHeight))
        let width = CGFloat(textureWidth) * scale
        let height = CGFloat(textureHeight) * scale
        return CGRect(x: cell.minX + (cell.width - width) / 2,
                      y: cell.minY + (cell.height - height) / 2,
                      width: width, height: height)
    }

    /// Upload changed tiles and draw the grid. `tiles` is the controller's
    /// full tile array; `range` selects this window's slice.
    public func draw(tiles: [any TileFrameSource], range: Range<Int>) {
        // Upload pass, before acquiring a drawable: replaceRegion copies
        // synchronously from the mapped shm pointer, no intermediate buffer.
        for (local, index) in range.enumerated() {
            guard index < tiles.count else { break }
            let tile = tiles[index]
            if let last = lastUploaded[local], tile.frameCount == last { continue }
            let texture = textures[local]
            let uploaded = tile.withFrontBuffer { pixels, bytesPerRow in
                texture.replace(
                    region: MTLRegionMake2D(0, 0, texture.width, texture.height),
                    mipmapLevel: 0, withBytes: pixels, bytesPerRow: bytesPerRow)
            }
            if let uploaded {
                needsPresent = lastUploaded[local] != uploaded.frameCount
                    || needsPresent
                lastUploaded[local] = uploaded.frameCount
            }
        }

        // A display link may fire more often than the helpers publish. Keep
        // the last CAMetalLayer contents instead of acquiring and presenting
        // an identical full-screen drawable. A resize still forces a draw.
        let drawableSize = metalLayer.drawableSize
        guard needsPresent || drawableSize != lastDrawnSize else { return }
        // Keep needsPresent set until a command buffer is committed, so a
        // temporarily starved CAMetalLayer cannot permanently drop an update.
        guard let drawable = metalLayer.nextDrawable() else { return }
        guard let commandBuffer = context.queue.makeCommandBuffer() else { return }

        let pass = MTLRenderPassDescriptor()
        pass.colorAttachments[0].texture = drawable.texture
        pass.colorAttachments[0].loadAction = .clear
        pass.colorAttachments[0].storeAction = .store
        pass.colorAttachments[0].clearColor = MTLClearColor(red: 0, green: 0, blue: 0, alpha: 1)
        guard let encoder = commandBuffer.makeRenderCommandEncoder(descriptor: pass) else { return }
        encoder.setRenderPipelineState(context.pipeline)
        encoder.setFragmentSamplerState(context.sampler, index: 0)

        let drawableWidth = CGFloat(drawable.texture.width)
        let drawableHeight = CGFloat(drawable.texture.height)

        // Aspect-fit letterbox in the cell (matches the old .resizeAspect),
        // computed in drawable pixels with row 0 = top, converted to NDC.
        func drawQuad(texture: MTLTexture, in cell: CGRect, brightness: Float) {
            let fit = Self.aspectFitRect(textureWidth: texture.width,
                                         textureHeight: texture.height, in: cell)
            var rect = SIMD4<Float>(
                Float(2 * fit.minX / drawableWidth - 1),
                Float(1 - 2 * fit.maxY / drawableHeight),
                Float(2 * fit.width / drawableWidth),
                Float(2 * fit.height / drawableHeight))
            encoder.setVertexBytes(&rect, length: MemoryLayout<SIMD4<Float>>.size, index: 0)
            var brightness = brightness
            encoder.setFragmentBytes(&brightness, length: MemoryLayout<Float>.size, index: 0)
            encoder.setFragmentTexture(texture, index: 0)
            encoder.drawPrimitives(type: .triangleStrip, vertexStart: 0, vertexCount: 4)
        }

        if let fullscreen = fullscreenTile, range.contains(fullscreen),
           fullscreen < tiles.count {
            // Takeover fullscreen: only the played tile, filling the window;
            // the cleared pass provides the letterbox bars. An unpublished
            // tile stays black, as it would in the grid.
            let local = fullscreen - range.lowerBound
            if lastUploaded[local] != nil {
                drawQuad(texture: textures[local],
                         in: CGRect(x: 0, y: 0,
                                    width: drawableWidth, height: drawableHeight),
                         brightness: 1)
            }
        } else {
            let cellWidth = drawableWidth / CGFloat(columns)
            let cellHeight = drawableHeight / CGFloat(rows)
            for (local, index) in range.enumerated() {
                guard index < tiles.count, lastUploaded[local] != nil else { continue }
                let col = local % columns
                let row = local / columns
                let cell = CGRect(x: CGFloat(col) * cellWidth,
                                  y: CGFloat(row) * cellHeight,
                                  width: cellWidth, height: cellHeight)
                let brightness: Float
                switch emphasis {
                case .none: brightness = 1
                case .spotlight(let tile): brightness = tile == index ? 1 : 0.35
                }
                drawQuad(texture: textures[local], in: cell, brightness: brightness)
            }
        }

        encoder.endEncoding()
        commandBuffer.present(drawable)
        commandBuffer.commit()
        lastDrawnSize = drawableSize
        needsPresent = false
    }
}
