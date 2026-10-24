import CoreGraphics
import Foundation
import Testing
@testable import GrabAndMove
@testable import MacToysCore

@Suite struct GrabAndMoveTests {
    let window = CGRect(x: 100, y: 200, width: 900, height: 600)

    @Test func cornersInOuterThirds() {
        #expect(GrabGeometry.edges(for: CGPoint(x: 150, y: 250), in: window) == [.left, .top])
        #expect(GrabGeometry.edges(for: CGPoint(x: 950, y: 250), in: window) == [.right, .top])
        #expect(GrabGeometry.edges(for: CGPoint(x: 150, y: 750), in: window) == [.left, .bottom])
        #expect(GrabGeometry.edges(for: CGPoint(x: 950, y: 790), in: window) == [.right, .bottom])
    }

    @Test func edgesInMiddleThirds() {
        #expect(GrabGeometry.edges(for: CGPoint(x: 550, y: 230), in: window) == .top)
        #expect(GrabGeometry.edges(for: CGPoint(x: 550, y: 780), in: window) == .bottom)
        #expect(GrabGeometry.edges(for: CGPoint(x: 120, y: 500), in: window) == .left)
        #expect(GrabGeometry.edges(for: CGPoint(x: 990, y: 500), in: window) == .right)
    }

    @Test func centerPicksNearestEdge() {
        // Center third of a wide window: top and bottom are nearer than the sides.
        #expect(GrabGeometry.edges(for: CGPoint(x: 550, y: 405), in: window) == .top)
        #expect(GrabGeometry.edges(for: CGPoint(x: 550, y: 595), in: window) == .bottom)
        // A tall window: the side edges are nearer than top/bottom.
        let tall = CGRect(x: 0, y: 0, width: 300, height: 1200)
        #expect(GrabGeometry.edges(for: CGPoint(x: 140, y: 600), in: tall) == .left)
        #expect(GrabGeometry.edges(for: CGPoint(x: 160, y: 600), in: tall) == .right)
        #expect(GrabGeometry.edges(for: .zero, in: .zero) == [.right, .bottom])
    }

    @Test func moveKeepsSize() {
        let r = GrabGeometry.moved(window, by: CGSize(width: -30.4, height: 12.6))
        #expect(r == CGRect(x: 70, y: 213, width: 900, height: 600))
    }

    @Test func resizeRightBottomGrows() {
        let r = GrabGeometry.resized(window, edges: [.right, .bottom], by: CGSize(width: 100, height: 50))
        #expect(r == CGRect(x: 100, y: 200, width: 1000, height: 650))
    }

    @Test func resizeLeftTopMovesOriginAndKeepsOppositeEdges() {
        let r = GrabGeometry.resized(window, edges: [.left, .top], by: CGSize(width: -50, height: 40))
        #expect(r == CGRect(x: 50, y: 240, width: 950, height: 560))
        #expect(r.maxX == window.maxX && r.maxY == window.maxY)
    }

    @Test func resizeSingleEdgeLeavesOtherAxisAlone() {
        let r = GrabGeometry.resized(window, edges: .top, by: CGSize(width: 300, height: -20))
        #expect(r == CGRect(x: 100, y: 180, width: 900, height: 620))
    }

    @Test func resizeStopsAtMinimumSize() {
        let min = GrabGeometry.minimumSize
        let shrunkRight = GrabGeometry.resized(window, edges: .right, by: CGSize(width: -2000, height: 0))
        #expect(shrunkRight.width == min.width)
        #expect(shrunkRight.minX == window.minX)
        let shrunkLeft = GrabGeometry.resized(window, edges: [.left, .top], by: CGSize(width: 2000, height: 2000))
        #expect(shrunkLeft.size == min)
        #expect(shrunkLeft.maxX == window.maxX && shrunkLeft.maxY == window.maxY)
    }

    @Test func tinyWindowsAreNotForcedLarger() {
        let small = CGRect(x: 0, y: 0, width: 120, height: 60)
        let r = GrabGeometry.resized(small, edges: .right, by: CGSize(width: -50, height: 0))
        #expect(r.width == 120)
        let grown = GrabGeometry.resized(small, edges: .right, by: CGSize(width: 50, height: 0))
        #expect(grown.width == 170)
    }

    @Test func clampedResizeKeepsOppositeEdgeAnchored() {
        let target = CGRect(x: 300, y: 200, width: 400, height: 600)
        let o = GrabGeometry.anchoredOrigin(for: target, actual: CGSize(width: 500, height: 600), edges: [.left])
        #expect(o == CGPoint(x: 200, y: 200))
        let o2 = GrabGeometry.anchoredOrigin(for: target, actual: CGSize(width: 500, height: 700), edges: [.right, .bottom])
        #expect(o2 == target.origin)
    }

    @Test func readoutMatchesDesign() {
        #expect(GrabGeometry.readout(CGRect(x: 412, y: 188, width: 1280, height: 820)) == "x 412  y 188  ·  1280 × 820")
    }

    @Test func activationModifiers() {
        #expect(GrabAndMoveSettings.Activation.controlCommand.modifiers == [.control, .command])
        #expect(GrabAndMoveSettings.Activation.function.modifiers == [.function])
        #expect(GrabAndMoveSettings.Activation.commandOption.keys == ["⌥", "⌘"])
        #expect(GrabAndMoveSettings().activation == .controlCommand)
    }

    @Test func settingsRoundTrip() {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let store = SettingsStore(directory: dir)
        var s = GrabAndMoveSettings()
        s.activation = .option
        s.excludedForModifierApps = ["Steam"]
        store.save(s, id: "grabandmove")
        #expect(store.load("grabandmove", default: GrabAndMoveSettings()) == s)
        try? FileManager.default.removeItem(at: dir)
    }
}
