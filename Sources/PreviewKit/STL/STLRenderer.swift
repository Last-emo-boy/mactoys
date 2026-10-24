import AppKit
import Metal
import SceneKit

/// Renders an `STLMesh` offscreen with SceneKit (key, fill and ambient light), or with a small
/// CoreGraphics rasterizer when no Metal device is available.
public enum STLRenderer {
    /// `color` and `background` are sRGB; a nil background renders transparent.
    public static func render(_ mesh: STLMesh, size: CGSize, color: CGColor, background: CGColor?) -> CGImage? {
        guard mesh.triangleCount > 0, let bounds = mesh.bounds else { return nil }
        if let device = MTLCreateSystemDefaultDevice(),
           let image = renderSceneKit(mesh, bounds: bounds, size: size, color: color, background: background, device: device) {
            return image
        }
        return renderSoftware(mesh, bounds: bounds, size: size, color: color, background: background)
    }

    /// Camera direction in SceneKit space (y up, +z toward the viewer): front right, above.
    static let viewDirection: SIMD3<Float> = {
        let d = SIMD3<Float>(0.85, 0.75, 1.35)
        return d / (d * d).sum().squareRoot()
    }()

    private static func renderSceneKit(_ mesh: STLMesh, bounds: (min: SIMD3<Float>, max: SIMD3<Float>), size: CGSize,
                                       color: CGColor, background: CGColor?, device: MTLDevice) -> CGImage? {
        // Interleaved float position + face normal; STL is z-up, SceneKit y-up: (x, y, z) → (x, z, -y).
        let count = mesh.triangleCount * 3
        var interleaved = [Float]()
        interleaved.reserveCapacity(count * 6)
        for t in 0..<mesh.triangleCount {
            let n = mesh.normal(ofTriangle: t)
            for v in 0..<3 {
                let p = mesh.vertices[t * 3 + v]
                interleaved.append(contentsOf: [p.x, p.z, -p.y, n.x, n.z, -n.y])
            }
        }
        let data = interleaved.withUnsafeBufferPointer { Data(buffer: $0) }
        let stride = 6 * MemoryLayout<Float>.size
        let positions = SCNGeometrySource(data: data, semantic: .vertex, vectorCount: count, usesFloatComponents: true,
                                          componentsPerVector: 3, bytesPerComponent: 4, dataOffset: 0, dataStride: stride)
        let normals = SCNGeometrySource(data: data, semantic: .normal, vectorCount: count, usesFloatComponents: true,
                                        componentsPerVector: 3, bytesPerComponent: 4, dataOffset: 12, dataStride: stride)
        let indices = (0..<UInt32(count)).map { $0 }
        let element = SCNGeometryElement(indices: indices, primitiveType: .triangles)
        let geometry = SCNGeometry(sources: [positions, normals], elements: [element])
        let material = SCNMaterial()
        material.lightingModel = .blinn
        material.diffuse.contents = NSColor(cgColor: color) ?? NSColor.systemBlue
        material.specular.contents = NSColor(white: 0.35, alpha: 1)
        material.shininess = 0.35
        material.isDoubleSided = true
        geometry.materials = [material]

        let scene = SCNScene()
        scene.background.contents = background.flatMap { NSColor(cgColor: $0) } ?? NSColor.clear
        let node = SCNNode(geometry: geometry)
        let lo = SIMD3<Float>(bounds.min.x, bounds.min.z, -bounds.max.y)
        let hi = SIMD3<Float>(bounds.max.x, bounds.max.z, -bounds.min.y)
        let center = (lo + hi) / 2
        let extent = hi - lo
        let radius = max(1e-3, (extent * extent).sum().squareRoot() / 2)
        node.position = SCNVector3(-center.x, -center.y, -center.z)
        scene.rootNode.addChildNode(node)

        let camera = SCNCamera()
        camera.fieldOfView = 26
        camera.zNear = Double(radius) * 0.01
        camera.zFar = Double(radius) * 40
        let cameraNode = SCNNode()
        cameraNode.camera = camera
        let aspect = Float(size.width / max(1, size.height))
        let halfFOV = Float(camera.fieldOfView * .pi / 360)
        // Fit the bounding sphere vertically, or horizontally for tall images.
        let fit = aspect >= 1 ? radius / sin(halfFOV) : radius / (sin(halfFOV) * aspect)
        let eye = viewDirection * fit * 1.08
        cameraNode.position = SCNVector3(eye.x, eye.y, eye.z)
        cameraNode.look(at: SCNVector3(0, 0, 0))
        scene.rootNode.addChildNode(cameraNode)

        let ambient = SCNNode()
        ambient.light = SCNLight()
        ambient.light?.type = .ambient
        ambient.light?.intensity = 380
        scene.rootNode.addChildNode(ambient)
        let key = SCNNode()
        key.light = SCNLight()
        key.light?.type = .directional
        key.light?.intensity = 900
        key.eulerAngles = SCNVector3(-0.85, 0.45, 0)
        scene.rootNode.addChildNode(key)
        let fill = SCNNode()
        fill.light = SCNLight()
        fill.light?.type = .directional
        fill.light?.intensity = 320
        fill.eulerAngles = SCNVector3(0.35, -2.4, 0)
        scene.rootNode.addChildNode(fill)

        let renderer = SCNRenderer(device: device, options: nil)
        renderer.scene = scene
        renderer.pointOfView = cameraNode
        renderer.autoenablesDefaultLighting = false
        let image = renderer.snapshot(atTime: 0, with: size, antialiasingMode: .multisampling4X)
        var rect = CGRect(origin: .zero, size: size)
        return image.cgImage(forProposedRect: &rect, context: nil, hints: nil)
    }

    /// Painter's-algorithm fallback with Lambert shading (orthographic, same viewing direction).
    static func renderSoftware(_ mesh: STLMesh, bounds: (min: SIMD3<Float>, max: SIMD3<Float>), size: CGSize,
                               color: CGColor, background: CGColor?) -> CGImage? {
        let w = max(1, Int(size.width)), h = max(1, Int(size.height))
        guard let ctx = ImageUtil.context(width: w, height: h) else { return nil }
        if let background { ctx.setFillColor(background); ctx.fill(CGRect(x: 0, y: 0, width: w, height: h)) }
        let forward = -viewDirection
        let worldUp = SIMD3<Float>(0, 1, 0)
        var right = SIMD3(forward.y * worldUp.z - forward.z * worldUp.y, forward.z * worldUp.x - forward.x * worldUp.z,
                          forward.x * worldUp.y - forward.y * worldUp.x)
        right /= (right * right).sum().squareRoot()
        let up = SIMD3(right.y * forward.z - right.z * forward.y, right.z * forward.x - right.x * forward.z,
                       right.x * forward.y - right.y * forward.x)
        let light = SIMD3<Float>(-0.4, 0.8, 0.6) / (SIMD3<Float>(-0.4, 0.8, 0.6) * SIMD3<Float>(-0.4, 0.8, 0.6)).sum().squareRoot()
        func toScene(_ p: SIMD3<Float>) -> SIMD3<Float> { SIMD3(p.x, p.z, -p.y) }
        let center = toScene((bounds.min + bounds.max) / 2)
        let step = max(1, mesh.triangleCount / 400_000)
        var tris: [(depth: Float, pts: [CGPoint], shade: Float)] = []
        tris.reserveCapacity(mesh.triangleCount / step)
        var minX = Float.greatestFiniteMagnitude, maxX = -Float.greatestFiniteMagnitude
        var minY = Float.greatestFiniteMagnitude, maxY = -Float.greatestFiniteMagnitude
        for t in Swift.stride(from: 0, to: mesh.triangleCount, by: step) {
            var pts: [CGPoint] = []
            var depth: Float = 0
            for v in 0..<3 {
                let p = toScene(mesh.vertices[t * 3 + v]) - center
                let x = (p * right).sum(), y = (p * up).sum()
                minX = min(minX, x); maxX = max(maxX, x); minY = min(minY, y); maxY = max(maxY, y)
                pts.append(CGPoint(x: CGFloat(x), y: CGFloat(y)))
                depth += (p * forward).sum()
            }
            let n = toScene(mesh.normal(ofTriangle: t))
            let shade = 0.35 + 0.65 * abs((n * light).sum())
            tris.append((depth, pts, shade))
        }
        tris.sort { $0.depth > $1.depth }
        let spanX = CGFloat(max(maxX - minX, 1e-3)), spanY = CGFloat(max(maxY - minY, 1e-3))
        let scale = min(CGFloat(w) * 0.88 / spanX, CGFloat(h) * 0.88 / spanY)
        let ox = CGFloat(w) / 2 - CGFloat(minX + maxX) / 2 * scale, oy = CGFloat(h) / 2 - CGFloat(minY + maxY) / 2 * scale
        let base = (NSColor(cgColor: color)?.usingColorSpace(.sRGB)) ?? .systemBlue
        for tri in tris {
            let s = CGFloat(tri.shade)
            ctx.setFillColor(CGColor(srgbRed: base.redComponent * s, green: base.greenComponent * s,
                                     blue: base.blueComponent * s, alpha: 1))
            ctx.move(to: CGPoint(x: tri.pts[0].x * scale + ox, y: tri.pts[0].y * scale + oy))
            ctx.addLine(to: CGPoint(x: tri.pts[1].x * scale + ox, y: tri.pts[1].y * scale + oy))
            ctx.addLine(to: CGPoint(x: tri.pts[2].x * scale + ox, y: tri.pts[2].y * scale + oy))
            ctx.closePath()
            ctx.fillPath()
        }
        return ctx.makeImage()
    }
}
