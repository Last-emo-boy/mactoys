import CoreGraphics
import Foundation
import Testing
@testable import PreviewKit

/// End-to-end checks of what the Quick Look extensions and Peek call, on real files.
@Suite struct PreviewKitRendererTests {
    private func write(_ name: String, _ contents: String, in dir: URL) throws -> URL {
        let url = dir.appendingPathComponent(name)
        try Data(contents.utf8).write(to: url)
        return url
    }

    private func tempDir() throws -> URL {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    @Test func textPages() throws {
        let dir = try tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let options = PreviewOptions()
        let md = try PreviewRenderer.html(for: try write("a.md", "# Hi\n\n- [x] ok", in: dir), kind: .markdown, options: options)
        #expect(md.contains("<h1 id=\"hi\">Hi</h1>") && md.contains("markdown-body"))
        let code = try PreviewRenderer.html(for: try write("a.py", "def f(): return 1\n", in: dir), kind: .code("python"), options: options)
        #expect(code.contains("<span class=\"kw\">def</span>"))
        let json = try PreviewRenderer.html(for: try write("a.json", #"{"a":1}"#, in: dir), kind: .json, options: options)
        #expect(json.contains("Formatted for reading"))
        #expect(json.contains("<span class=\"prop\">&quot;a&quot;</span>"))
        let csv = try PreviewRenderer.html(for: try write("a.tsv", "x\ty\n1\t2\n", in: dir), kind: .delimited, options: options)
        #expect(csv.contains("<td class=\"num\">2</td>") && csv.contains("Tab-separated"))
        let script = PreviewRenderer.codePage("#!/bin/sh\necho hi\n", fileName: "run", kind: .code("text"), options: options)
        #expect(script.contains("<span class=\"bi\">echo</span>"))
    }

    @Test func limitsAndBinaryFiles() throws {
        let dir = try tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        var options = PreviewOptions()
        options.maxTextBytes = 8
        #expect(throws: PreviewError.tooLarge(20)) {
            try PreviewRenderer.html(for: try write("big.txt", String(repeating: "x", count: 20), in: dir), kind: .code("text"), options: options)
        }
        let bin = dir.appendingPathComponent("bin.c")
        try Data([0x00, 0x01, 0x02, 0x00, 0xFF]).write(to: bin)
        #expect(throws: PreviewError.binary) { try PreviewRenderer.html(for: bin, kind: .code("c"), options: PreviewOptions()) }
    }

    @Test func graphicsAndThumbnails() async throws {
        let dir = try tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let options = PreviewOptions()
        let size = CGSize(width: 200, height: 150)

        let svg = try write("a.svg", #"<svg xmlns="http://www.w3.org/2000/svg" width="40" height="20"><rect width="40" height="20" fill="red"/></svg>"#, in: dir)
        let svgImage = try await PreviewRenderer.image(for: svg, kind: .svg, maxSize: size, options: options)
        #expect(svgImage.width == 200 && svgImage.height == 100)

        let gcode = try write("a.gcode", "G1 Z0.2\nG1 X0 Y0\nG1 X10 Y0 E1\nG1 X10 Y10 E2\n", in: dir)
        #expect(try await PreviewRenderer.image(for: gcode, kind: .gcode, maxSize: size, options: options).width == 200)

        let stl = try write("a.stl", "solid t\nfacet normal 0 0 1\nouter loop\nvertex 0 0 0\nvertex 1 0 0\nvertex 0 1 0\nendloop\nendfacet\nendsolid t\n", in: dir)
        #expect(try await PreviewRenderer.image(for: stl, kind: .stl, maxSize: size, options: options).width == 200)

        let qoi = dir.appendingPathComponent("a.qoi")
        try Data(PreviewKitFormatTests.qoiBytes).write(to: qoi)
        let qoiImage = try await PreviewRenderer.image(for: qoi, kind: .qoi, maxSize: size, options: options)
        #expect(qoiImage.width == 3)
        #expect(ImageUtil.pixelSize(of: qoi) == CGSize(width: 3, height: 2))

        let settings = FinderAddonsSettings()
        let md = try write("b.md", "# Title\n\nSome text.", in: dir)
        let mdThumb = try await PreviewRenderer.thumbnail(for: md, kind: .markdown, maxSize: CGSize(width: 128, height: 128), settings: settings)
        #expect(mdThumb.width == 128)
        let gThumb = try await PreviewRenderer.thumbnail(for: gcode, kind: .gcode, maxSize: CGSize(width: 64, height: 64), settings: settings)
        #expect(gThumb.width == 64)
        await #expect(throws: PreviewError.unsupported) {
            try await PreviewRenderer.thumbnail(for: md, kind: .code("swift"), maxSize: size, settings: settings)
        }
    }

    @Test func folderSummaryCountsEverything() throws {
        let dir = try tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        try FileManager.default.createDirectory(at: dir.appendingPathComponent("sub/deeper"), withIntermediateDirectories: true)
        try Data(count: 100).write(to: dir.appendingPathComponent("a.bin"))
        try Data(count: 50).write(to: dir.appendingPathComponent("sub/b.bin"))
        try Data(count: 5).write(to: dir.appendingPathComponent("sub/deeper/c.bin"))
        var updates = 0
        let s = FolderSummary.scan(dir, progress: { _ in updates += 1 })
        #expect(s.files == 3 && s.folders == 2 && s.bytes == 155)
        #expect(s.finished && !s.incomplete && updates >= 1)
        let stopped = FolderSummary.scan(dir, progress: { _ in }, isCancelled: { true })
        #expect(!stopped.finished)
    }
}
