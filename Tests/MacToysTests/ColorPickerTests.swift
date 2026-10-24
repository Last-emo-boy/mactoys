import Foundation
import Testing
@testable import ColorPicker
@testable import MacToysCore

@Suite struct ColorPickerTests {
    let coral = ColorValue(red: 255, green: 95, blue: 74)       // #FF5F4A, design 06
    let red = ColorValue(red: 255, green: 0, blue: 0)
    let green = ColorValue(red: 0, green: 255, blue: 0)
    let blue = ColorValue(red: 0, green: 0, blue: 255)
    let white = ColorValue(red: 255, green: 255, blue: 255)
    let black = ColorValue(red: 0, green: 0, blue: 0)
    let gray = ColorValue(red: 128, green: 128, blue: 128)

    private func close(_ a: Double, _ b: Double, _ tolerance: Double = 0.005) -> Bool { abs(a - b) <= tolerance }

    // MARK: ColorValue

    @Test func hexRoundTripAndCoding() throws {
        #expect(ColorValue(hex: "#ff5f4a") == coral)
        #expect(coral.hex == "#FF5F4A")
        #expect(ColorValue(hex: "zz") == nil)
        let data = try JSONEncoder().encode([coral, ColorValue(red: 1, green: 2, blue: 3, alpha: 128)])
        #expect(String(decoding: data, as: UTF8.self) == ##"["#FF5F4A","#01020380"]"##)
        let back = try JSONDecoder().decode([ColorValue].self, from: data)
        #expect(back[0] == coral && back[1].alpha == 128)
    }

    // MARK: Cylindrical spaces

    @Test func hueMatchesSystemDrawing() {
        #expect(ColorMath.hue(red) == 0)
        #expect(ColorMath.hue(green) == 120)
        #expect(ColorMath.hue(blue) == 240)
        #expect(ColorMath.hue(gray) == 0)
        #expect(close(ColorMath.hue(ColorValue(red: 255, green: 0, blue: 128)), 329.882, 0.01))
        #expect(close(ColorMath.hue(coral), 6.9613, 0.001))
    }

    @Test func hsvHslHsiHwb() {
        let hsv = ColorMath.hsv(coral)
        #expect(close(hsv.saturation, 0.7098) && hsv.value == 1)
        let hsl = ColorMath.hsl(coral)
        #expect(close(hsl.saturation, 1) && close(hsl.lightness, 0.6451))
        let darkHSL = ColorMath.hsl(ColorValue(red: 64, green: 32, blue: 32))
        #expect(close(darkHSL.saturation, 0.3333) && close(darkHSL.lightness, 0.1882))
        #expect(ColorMath.hsl(gray).saturation == 0)
        let hsi = ColorMath.hsi(coral)
        #expect(close(hsi.intensity, 0.5542) && close(hsi.saturation, 0.4764))
        #expect(ColorMath.hsi(black) == (0, 0, 0))
        let hwb = ColorMath.hwb(coral)
        #expect(close(hwb.whiteness, 0.2902) && hwb.blackness == 0)
    }

    @Test func cmyk() {
        let c = ColorMath.cmyk(coral)
        #expect(c.cyan == 0 && close(c.magenta, 0.6275) && close(c.yellow, 0.7098) && c.black == 0)
        #expect(ColorMath.cmyk(black) == (0, 0, 0, 1))
        let navy = ColorMath.cmyk(ColorValue(red: 0, green: 0, blue: 128))
        #expect(navy.cyan == 1 && navy.magenta == 1 && navy.yellow == 0 && close(navy.black, 0.498))
    }

    @Test func naturalHue() {
        #expect(ColorMath.naturalHue(red) == "R0")
        #expect(ColorMath.naturalHue(coral) == "R12")
        #expect(ColorMath.naturalHue(green) == "G0")
        #expect(ColorMath.naturalHue(ColorValue(red: 255, green: 0, blue: 128)) == "M50")
    }

    // MARK: CIE and Oklab (reference values from the CIE / Ottosson definitions)

    @Test func xyzReferenceValues() {
        let r = ColorMath.xyz(red)
        #expect(close(r.x, 0.412391, 1e-6) && close(r.y, 0.212639, 1e-6) && close(r.z, 0.019331, 1e-6))
        let w = ColorMath.xyz(white)
        #expect(close(w.x, 0.950456, 1e-6) && close(w.y, 1, 1e-6) && close(w.z, 1.089058, 1e-6))
        #expect(ColorMath.xyz(black) == (0, 0, 0))
    }

    @Test func labReferenceValues() {
        let r = ColorMath.lab(red)
        #expect(close(r.l, 53.24) && close(r.a, 80.09, 0.01) && close(r.b, 67.20, 0.01))
        let b = ColorMath.lab(blue)
        #expect(close(b.l, 32.30, 0.01) && close(b.a, 79.20, 0.01) && close(b.b, -107.86, 0.01))
        let w = ColorMath.lab(white)
        #expect(close(w.l, 100, 0.001) && close(w.a, 0, 0.001) && close(w.b, 0, 0.001))
        #expect(close(ColorMath.lab(gray).l, 53.59, 0.01))
    }

    @Test func oklabReferenceValues() {
        let r = ColorMath.oklab(red)
        #expect(close(r.l, 0.62796, 1e-4) && close(r.a, 0.22486, 1e-4) && close(r.b, 0.12585, 1e-4))
        let w = ColorMath.oklab(white)
        #expect(close(w.l, 1, 1e-4) && close(w.a, 0, 1e-4) && close(w.b, 0, 1e-4))
        let lch = ColorMath.oklch(red)
        #expect(close(lch.c, 0.25768, 1e-4) && close(lch.h, 29.234, 0.01))
        #expect(close(ColorMath.oklch(green).h, 142.495, 0.01))
        #expect(close(ColorMath.oklch(blue).h, 264.052, 0.01))
        #expect(ColorMath.oklch(gray).h == 0)
    }

    @Test func inverseConversionsRoundTrip() {
        for c in [coral, red, green, blue, white, black, gray, ColorValue(red: 10, green: 132, blue: 255)] {
            let hsv = ColorMath.hsv(c)
            #expect(ColorMath.fromHSV(hue: hsv.hue, saturation: hsv.saturation, value: hsv.value) == c)
            let hsl = ColorMath.hsl(c)
            #expect(ColorMath.fromHSL(hue: hsl.hue, saturation: hsl.saturation, lightness: hsl.lightness) == c)
        }
    }

    @Test func shadesAreOrderedAndDistinct() {
        let shades = ColorMath.shades(of: coral)
        #expect(shades.count == 5 && shades[2] == coral)
        let lightness = shades.map { ColorMath.hsl($0).lightness }
        #expect(lightness == lightness.sorted())
        #expect(Set(shades).count == 5)
        #expect(Set(ColorMath.shades(of: ColorValue(red: 250, green: 250, blue: 252))).count >= 3)
    }

    // MARK: Formats

    private func formatted(_ name: String, _ color: ColorValue? = nil) -> String {
        let f = ColorFormat.builtIns.first { $0.name == name }!
        return ColorFormatter.format(color ?? coral, f.format)
    }

    @Test func builtInFormats() {
        #expect(formatted("HEX") == "#FF5F4A")
        #expect(formatted("RGB") == "rgb(255, 95, 74)")
        #expect(formatted("HSL") == "hsl(7, 100%, 65%)")
        #expect(formatted("HSV") == "hsv(7, 71%, 100%)")
        #expect(formatted("HSB") == "hsb(7, 71%, 100%)")
        #expect(formatted("HSI") == "hsi(7, 48%, 55%)")
        #expect(formatted("HWB") == "hwb(7, 29%, 0%)")
        #expect(formatted("CMYK") == "cmyk(0%, 63%, 71%, 0%)")
        #expect(formatted("NCol") == "R12, 29%, 0%")
        #expect(formatted("CIELAB") == "CIELab(61.6, 59.67, 44.16)")
        #expect(formatted("CIEXYZ") == "XYZ(46.567, 29.9423, 9.8062)")
        #expect(formatted("OKLAB") == "oklab(69.2% 0.17 0.1)")
        #expect(formatted("OKLCH") == "oklch(69.2% 0.2 30)")
        #expect(formatted("VEC4") == "(1f, 0.37f, 0.29f, 1f)")
        #expect(formatted("Decimal") == "16736074")
        #expect(formatted("HEX Int") == "0xFFFF5F4A")
        #expect(formatted("SwiftUI") == "Color(red: 1, green: 0.37, blue: 0.29)")
        #expect(formatted("NSColor") == "NSColor(srgbRed: 1, green: 0.37, blue: 0.29, alpha: 1)")
        #expect(formatted("CSS Name") == "tomato")
        #expect(formatted("CIELAB", white) == "CIELab(100, 0, 0)")
        #expect(formatted("OKLCH", black) == "oklch(0% 0 0)")
    }

    @Test func customFormatTokens() {
        #expect(ColorFormatter.format(coral, "%Reh%ReH|%Rex%GrX|%Ref %GrF %BlF") == "fF|ff5F|1 .37 .29")
        #expect(ColorFormatter.format(coral, ColorFormat.newFormatTemplate) == "new Color (R = 255, G = 95, B = 74)")
        #expect(ColorFormatter.format(coral, "%Al %Dv %Dr") == "255 4874239 16736074")
        #expect(ColorFormatter.format(coral, "%Lci, %Cai, %Cbi") == "62, 60, 44")
        #expect(ColorFormatter.format(coral, "%Na") == "Red")
        // Unknown parameters and a trailing % pass through untouched.
        #expect(ColorFormatter.format(coral, "100% %Zz %") == "100% %Zz %")
        #expect(ColorFormatter.format(coral, "%Re") == "255")
        #expect(ColorFormatter.format(coral, "%R") == "%R")
        // Negative zero never appears.
        #expect(ColorFormatter.format(ColorValue(red: 128, green: 128, blue: 128), "%Ca/%Cb") == "0/0")
    }

    @Test func colorNames() {
        #expect(ColorNames.name(for: white) == "White")
        #expect(ColorNames.name(for: black) == "Black")
        #expect(ColorNames.name(for: gray) == "Gray")
        #expect(ColorNames.name(for: ColorValue(red: 200, green: 200, blue: 200)) == "Light Gray")
        #expect(ColorNames.name(for: red) == "Red")
        #expect(ColorNames.name(for: green) == "Green")
        #expect(ColorNames.name(for: ColorValue(red: 0, green: 100, blue: 0)) == "Dark Green")
        #expect(ColorNames.name(for: blue) == "Blue")
        #expect(ColorNames.nearestCSS(to: ColorValue(red: 0x64, green: 0x95, blue: 0xED)) == "cornflowerblue")
        #expect(ColorNames.nearestCSS(to: ColorValue(red: 254, green: 1, blue: 2)) == "red")
        #expect(Set(ColorNames.css.map(\.name)).count == ColorNames.css.count)
    }

    @Test func formatListNormalization() {
        var stored = ColorFormat.builtIns.filter { $0.name != "CSS Name" }
        stored[0].enabled = false
        stored.swapAt(0, 1)
        stored.append(ColorFormat(name: "Mine", format: "%Re"))
        stored.append(ColorFormat(name: "Mine", format: "dup"))
        let list = stored.normalized()
        #expect(list.first?.name == "RGB")
        #expect(list.first { $0.name == "HEX" }?.enabled == false)
        #expect(list.filter { $0.name == "Mine" }.count == 1)
        #expect(list.last?.name == "CSS Name" && list.last?.enabled == false)
        #expect([ColorFormat]().normalized() == ColorFormat.builtIns)
    }

    @MainActor @Test func historyPersistsAndCaps() throws {
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("history-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: file) }
        let history = ColorHistory(file: file, limit: 3)
        for c in [red, green, blue, white] { history.add(c) }
        #expect(history.colors == [white, blue, green])
        history.add(green)
        #expect(history.colors == [green, white, blue])
        history.remove(white)
        let reloaded = ColorHistory(file: file, limit: 3)
        #expect(reloaded.colors == [green, blue])
        reloaded.clear()
        #expect(ColorHistory(file: file).colors.isEmpty)
    }

    @Test func settingsRoundTrip() throws {
        var s = ColorPickerSettings()
        s.activation = .pickOnly
        s.formats.append(ColorFormat(name: "Mine", format: "%Re"))
        let back = try JSONDecoder().decode(ColorPickerSettings.self, from: JSONEncoder().encode(s))
        #expect(back == s)
        #expect(s.copyFormat.name == "HEX")
        #expect(s.action(forButton: 0) == .pickThenEditor && s.action(forButton: 2) == .pickAndClose)
    }
}
