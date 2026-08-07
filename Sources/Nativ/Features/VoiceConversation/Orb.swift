/*
 * Original work Copyright 2024 LiveKit, Inc.
 * Modifications Copyright 2025 Eleven Labs Inc.
 *
 * Licensed under the Apache License, Version 2.0 (the "License");
 * you may not use this file except in compliance with the License.
 * You may obtain a copy of the License at
 *
 *     http://www.apache.org/licenses/LICENSE-2.0
 *
 * Unless required by applicable law or agreed to in writing, software
 * distributed under the License is distributed on an "AS IS" BASIS,
 * WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
 * See the License for the specific language governing permissions and
 * limitations under the License.
 */

// Vendored from ElevenLabs components-swift (Apache-2.0). The LiveKit-backed
// `OrbVisualizer` wrapper and `import LiveKit` were removed — the `Orb` view is
// self-contained and driven by plain Float volumes + a VisualizerAgentState.
// Backed by the sibling `OrbShader.metal`, compiled into the app's default
// Metal library.

import Foundation
import MetalKit
import simd
import SwiftUI

#if os(macOS)
import AppKit
#else
import UIKit
#endif

/// CPU-side uniforms must match `OrbUniforms` in `OrbShader.metal` byte‑for‑byte.
/// Stride = 96 bytes.
struct OrbUniforms {
    var time: Float = 0
    var animation: Float = 0
    var inverted: Float = 0
    var _pad0: Float = 0 // 16‑byte align
    var offsets: simd_float8 = .zero // only first 7 used
    var color1: simd_float4 = .zero
    var color2: simd_float4 = .zero
    var inputVolume: Float = 0
    var outputVolume: Float = 0
    var _pad1: SIMD2<Float> = .zero // to 96 bytes

    init() {}
}

/// Convert SwiftUI `Color` -> linear‑space simd_float4.
@inline(__always)
private func colorToSIMD4(_ color: Color) -> simd_float4 {
    #if os(macOS)
    let ns = NSColor(color)
    let rgb = ns.usingColorSpace(.deviceRGB) ?? ns
    var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 1
    rgb.getRed(&r, green: &g, blue: &b, alpha: &a)
    #else
    let ui = UIColor(color)
    var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 1
    ui.getRed(&r, green: &g, blue: &b, alpha: &a)
    #endif
    func sRGBToLinear(_ v: CGFloat) -> Float {
        if v <= 0.04045 { return Float(v / 12.92) }
        return Float(pow((v + 0.055) / 1.055, 2.4))
    }
    return .init(sRGBToLinear(r), sRGBToLinear(g), sRGBToLinear(b), Float(a))
}

/// Shared Metal renderer backing the SwiftUI representables.
class MetalOrbRenderer: NSObject, MTKViewDelegate {
    private let device: MTLDevice
    private let commandQueue: MTLCommandQueue
    private var pipeline: MTLRenderPipelineState!
    private var vertexBuffer: MTLBuffer!

    private var startTime: CFTimeInterval = CACurrentMediaTime()
    private var animationTime: Float = 0

    private var uniforms = OrbUniforms()
    private var randomOffsets: [Float] = []
    private var currentAgentState: VisualizerAgentState = .unknown

    // Eased targets: the shader uniforms glide toward these each frame so state
    // colors cross-fade and audio levels follow an attack/release envelope.
    private var targetColor1 = simd_float4(repeating: 0)
    private var targetColor2 = simd_float4(repeating: 0)
    private var targetInput: Float = 0
    private var targetOutput: Float = 0

    // MARK: - Init

    override init() {
        guard let d = MTLCreateSystemDefaultDevice(), let q = d.makeCommandQueue() else {
            fatalError("Metal not available")
        }
        device = d
        commandQueue = q
        super.init()
        generateRandomOffsets()
        buildBuffers()
        buildPipeline()
    }

    // MARK: - Public updaters

    func updateColors(color1: Color, color2: Color) {
        targetColor1 = colorToSIMD4(color1)
        targetColor2 = colorToSIMD4(color2)
    }

    func updateVolumes(input: Float, output: Float) {
        targetInput = max(0, min(1, input))
        targetOutput = max(0, min(1, output))
    }

    func updateAgentState(_ state: VisualizerAgentState) {
        // No longer inverting colors for thinking state
        uniforms.inverted = 0
        currentAgentState = state
    }

    // MARK: - MTKViewDelegate

    func mtkView(_: MTKView, drawableSizeWillChange _: CGSize) {}

    func draw(in view: MTKView) {
        guard let drawable = view.currentDrawable,
              let rpd = view.currentRenderPassDescriptor,
              let cmd = commandQueue.makeCommandBuffer(),
              let enc = cmd.makeRenderCommandEncoder(descriptor: rpd) else { return }

        let fps = max(view.preferredFramesPerSecond, 1)
        uniforms.time = Float(CACurrentMediaTime() - startTime)
        let t = uniforms.time

        // Glide the state colors toward their target so transitions cross-fade.
        let colorRate: Float = 0.14
        uniforms.color1 += (targetColor1 - uniforms.color1) * colorRate
        uniforms.color2 += (targetColor2 - uniforms.color2) * colorRate

        // Envelope-follow the audio levels: fast attack, slow release.
        uniforms.inputVolume = Self.follow(uniforms.inputVolume, targetInput)
        uniforms.outputVolume = Self.follow(uniforms.outputVolume, targetOutput)

        // Deliberate motion per state so the orb is never frozen: a breathing
        // ripple while thinking, a gentle pulse while listening at rest.
        switch currentAgentState {
        case .thinking:
            uniforms.outputVolume = max(uniforms.outputVolume, 0.12 + 0.10 * sin(t * 2.1))
            uniforms.inputVolume = max(uniforms.inputVolume, 0.08 + 0.06 * sin(t * 1.4))
        case .listening:
            uniforms.inputVolume = max(uniforms.inputVolume, 0.05 + 0.04 * sin(t * 1.2))
        default:
            break
        }

        // Thinking eases the flow speed rather than freezing it.
        let animationSpeed: Float = currentAgentState == .thinking ? 0.05 : 0.1
        animationTime += (1.0 / Float(fps)) * animationSpeed
        uniforms.animation = animationTime
        uniforms.offsets = simd_float8(randomOffsets + [0])

        enc.setRenderPipelineState(pipeline)
        enc.setVertexBuffer(vertexBuffer, offset: 0, index: 0)

        var u = uniforms
        enc.setFragmentBytes(&u, length: MemoryLayout<OrbUniforms>.stride, index: 0)

        enc.drawPrimitives(type: .triangleStrip, vertexStart: 0, vertexCount: 4)
        enc.endEncoding()
        cmd.present(drawable)
        cmd.commit()
    }

    // MARK: - Private

    /// Attack/release envelope follower: rises quickly toward a louder target,
    /// falls back slowly, so the orb pops on speech and eases down organically.
    private static func follow(_ current: Float, _ target: Float) -> Float {
        let rate: Float = target > current ? 0.5 : 0.08
        return current + (target - current) * rate
    }

    private func generateRandomOffsets() {
        randomOffsets = (0 ..< 7).map { _ in Float.random(in: 0 ... (Float.pi * 2)) }
    }

    private func buildBuffers() {
        // full‑screen quad
        let verts: [Float] = [
            -1, 1,
            -1, -1,
            1, 1,
            1, -1,
        ]
        vertexBuffer = device.makeBuffer(bytes: verts, length: verts.count * MemoryLayout<Float>.size, options: [])
    }

    private func buildPipeline() {
        // Metal file is compiled into the app's default library.
        var lib: MTLLibrary? = device.makeDefaultLibrary()
        if lib == nil {
            lib = try? device.makeDefaultLibrary(bundle: Bundle(for: type(of: self)))
        }
        if lib == nil {
            lib = try? device.makeDefaultLibrary(bundle: .main)
        }

        guard let library = lib else {
            fatalError("Unable to load Metal library – ensure OrbShader.metal is included in the target")
        }

        guard let vfn = library.makeFunction(name: "orbVertexShader"),
              let ffn = library.makeFunction(name: "orbFragmentShader")
        else {
            fatalError("Unable to find shader functions in Metal library")
        }

        let desc = MTLRenderPipelineDescriptor()
        desc.vertexFunction = vfn
        desc.fragmentFunction = ffn
        desc.colorAttachments[0].pixelFormat = .bgra8Unorm

        do {
            pipeline = try device.makeRenderPipelineState(descriptor: desc)
        } catch {
            fatalError("Orb pipeline creation failed: \(error)")
        }
    }
}

#if os(macOS)
struct _OrbPlatformView: NSViewRepresentable {
    var color1: Color
    var color2: Color
    var inputVolume: Float
    var outputVolume: Float
    var agentState: VisualizerAgentState

    func makeNSView(context: Context) -> MTKView {
        let view = MTKView()
        view.device = MTLCreateSystemDefaultDevice()
        view.delegate = context.coordinator
        configure(view: view)
        context.coordinator.updateAll(color1: color1, color2: color2, input: inputVolume, output: outputVolume, state: agentState)
        return view
    }

    func updateNSView(_: MTKView, context: Context) {
        context.coordinator.updateAll(color1: color1, color2: color2, input: inputVolume, output: outputVolume, state: agentState)
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    private func configure(view: MTKView) {
        view.framebufferOnly = false
        view.isPaused = false
        view.enableSetNeedsDisplay = false
        view.preferredFramesPerSecond = 60
        view.clearColor = .init(red: 0, green: 0, blue: 0, alpha: 0)
        view.colorPixelFormat = .bgra8Unorm
        view.autoResizeDrawable = true
    }

    final class Coordinator: MetalOrbRenderer {
        func updateAll(color1: Color, color2: Color, input: Float, output: Float, state: VisualizerAgentState) {
            updateColors(color1: color1, color2: color2)
            updateVolumes(input: input, output: output)
            updateAgentState(state)
        }
    }
}
#else
struct _OrbPlatformView: UIViewRepresentable {
    var color1: Color
    var color2: Color
    var inputVolume: Float
    var outputVolume: Float
    var agentState: VisualizerAgentState

    func makeUIView(context: Context) -> MTKView {
        let view = MTKView()
        view.device = MTLCreateSystemDefaultDevice()
        view.delegate = context.coordinator
        configure(view: view)
        context.coordinator.updateAll(color1: color1, color2: color2, input: inputVolume, output: outputVolume, state: agentState)
        return view
    }

    func updateUIView(_: MTKView, context: Context) {
        context.coordinator.updateAll(color1: color1, color2: color2, input: inputVolume, output: outputVolume, state: agentState)
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    private func configure(view: MTKView) {
        view.framebufferOnly = false
        view.isPaused = false
        view.enableSetNeedsDisplay = false
        view.preferredFramesPerSecond = 60
        view.clearColor = .init(red: 0, green: 0, blue: 0, alpha: 0)
        view.colorPixelFormat = .bgra8Unorm
        view.autoResizeDrawable = true
    }

    final class Coordinator: MetalOrbRenderer {
        func updateAll(color1: Color, color2: Color, input: Float, output: Float, state: VisualizerAgentState) {
            updateColors(color1: color1, color2: color2)
            updateVolumes(input: input, output: output)
            updateAgentState(state)
        }
    }
}
#endif

/// A SwiftUI view that renders the animated audio orb, driven by input/output
/// volumes (0…1) and an agent state.
public struct Orb: View {
    public var color1: Color
    public var color2: Color
    public var inputVolume: Float
    public var outputVolume: Float
    public var agentState: VisualizerAgentState

    public init(color1: Color, color2: Color, inputVolume: Float, outputVolume: Float, agentState: VisualizerAgentState = .unknown) {
        self.color1 = color1
        self.color2 = color2
        self.inputVolume = inputVolume
        self.outputVolume = outputVolume
        self.agentState = agentState
    }

    public var body: some View {
        GeometryReader { geo in
            let side = max(1, min(geo.size.width, geo.size.height))
            _OrbPlatformView(
                color1: color1,
                color2: color2,
                inputVolume: inputVolume,
                outputVolume: outputVolume,
                agentState: agentState
            )
            .frame(width: side, height: side)
            .clipShape(Circle())
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .accessibilityLabel(Text("Orb visualizer"))
        }
        .aspectRatio(1, contentMode: .fit)
    }
}
