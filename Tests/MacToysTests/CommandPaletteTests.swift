import Foundation
import Testing
@testable import CommandPalette
@testable import MacToysCore

// MARK: - Calculator

@Suite struct CalculatorTests {
    let calc = Calculator()

    func value(_ s: String, _ c: Calculator? = nil) throws -> Double {
        try (c ?? calc).evaluate(s).value
    }

    func close(_ a: Double, _ b: Double, _ eps: Double = 1e-9) -> Bool { abs(a - b) <= eps * max(1, abs(b)) }

    @Test func precedence() throws {
        #expect(try value("2+3*4") == 14)
        #expect(try value("(2+3)*4") == 20)
        #expect(try value("10-4-3") == 3)
        #expect(try value("100/10/5") == 2)
        #expect(try value("2*3^2") == 18)
        #expect(try value("2^3^2") == 512)          // right associative
        #expect(try value("7 - 2 * 3 + 1") == 2)
        #expect(try value("1 + 2 × 3 ÷ 4 − 5") == -2.5)
        #expect(try value("2 ** 10") == 1024)
    }

    @Test func unaryMinus() throws {
        #expect(try value("-2^2") == -4)
        #expect(try value("(-2)^2") == 4)
        #expect(try value("2^-1") == 0.5)
        #expect(try value("--3") == 3)
        #expect(try value("-(1+2)") == -3)
        #expect(try value("3 - -2") == 5)
        #expect(try value("+5") == 5)
    }

    @Test func implicitMultiplication() throws {
        #expect(try value("2(3+4)") == 14)
        #expect(try value("(1+2)(3+4)") == 21)
        #expect(close(try value("2pi"), 2 * .pi))
        #expect(close(try value("1/2pi"), 1 / (2 * .pi)))
        #expect(try value("3 sqrt(16)") == 12)
        #expect(throws: CalcError.self) { try calc.evaluate("2 3") }
    }

    @Test func functionsAndConstants() throws {
        #expect(close(try value("sqrt(2) * 100"), 141.4213562373095))
        #expect(close(try value("sin(pi/2)"), 1))
        #expect(close(try value("cos(0)"), 1))
        #expect(close(try value("tan(pi/4)"), 1))
        #expect(close(try value("log(1000)"), 3))
        #expect(close(try value("ln(e)"), 1))
        #expect(try value("abs(-4.5)") == 4.5)
        #expect(try value("round(2.5)") == 3)
        #expect(try value("round(3.14159, 2)") == 3.14)
        #expect(try value("floor(-1.5)") == -2)
        #expect(try value("ceil(1.2)") == 2)
        #expect(try value("min(3, 7, 2)") == 2)
        #expect(try value("max(3, 7, 2)") == 7)
        #expect(try value("pow(2, 8)") == 256)
        #expect(try value("5!") == 120)
        #expect(try value("logn(8, 2)") == 3)
        #expect(try value("root(27, 3)") == 3)
        #expect(try value("root(-8, 3)") == -2)
        #expect(try value("sqrt 16") == 4)
        #expect(try value("√9") == 3)
        #expect(close(try value("π"), .pi))
        #expect(try value("gcd(12, 18)") == 6)
        #expect(try value("lcm(4, 6)") == 12)
        #expect(try value("sign(-3)") == -1)
    }

    @Test func degrees() throws {
        let deg = Calculator(angleUnit: .degrees)
        #expect(close(try value("sin(90)", deg), 1))
        #expect(close(try value("asin(1)", deg), 90))
        #expect(close(try value("cos(180)", deg), -1))
    }

    @Test func percentAndModulo() throws {
        #expect(try value("10 % 3") == 1)
        #expect(try value("50%") == 0.5)
        #expect(close(try value("200 + 10%"), 220))
        #expect(close(try value("200 - 25%"), 150))
        #expect(close(try value("80 * 15%"), 12))
        #expect(close(try value("15% of 80"), 12))
        #expect(try value("17 mod 5") == 2)
    }

    @Test func numberLiterals() throws {
        #expect(try value("0xFF") == 255)
        #expect(try value("0xff + 1") == 256)
        #expect(try value("0b1010") == 10)
        #expect(try value("0o17") == 15)
        #expect(try value("1e3") == 1000)
        #expect(try value("2.5e-1") == 0.25)
        #expect(try value(".5 + .5") == 1)
        #expect(try value("1_000_000") == 1_000_000)
        #expect(close(try value("2e"), 2 * M_E))   // 2·e, not an exponent
    }

    @Test func outputBases() throws {
        let r = try calc.evaluate("255 in hex")
        #expect(r.base == .hex)
        #expect(CalcFormatter.integer(r.value, base: .hex) == "0xFF")
        #expect(try calc.evaluate("10 to bin").base == .binary)
        #expect(CalcFormatter.integer(10, base: .binary) == "0b1010")
        #expect(CalcFormatter.integer(8, base: .octal) == "0o10")
        #expect(CalcFormatter.integer(-1, base: .hex) == "0xFFFFFFFFFFFFFFFF")
        #expect(CalcFormatter.integer(1.5, base: .hex) == nil)
    }

    @Test func formatting() {
        #expect(CalcFormatter.decimal(141.4213562373095) == "141.42135623731")
        #expect(CalcFormatter.decimal(0.1 + 0.2) == "0.3")
        #expect(CalcFormatter.decimal(-0.0) == "0")
        #expect(CalcFormatter.decimal(1e20) == "1e20")
        #expect(CalcFormatter.decimal(1.5e-12) == "1.5e-12")
        #expect(CalcFormatter.scientific(141.4213562373095) == "1.4142135623731 × 10²")
        #expect(CalcFormatter.scientific(0.00012) == "1.2 × 10⁻⁴")
        #expect(CalcFormatter.scientific(5) == "5")
    }

    @Test func triviality() throws {
        #expect(try calc.evaluate("42").isTrivial)
        #expect(try calc.evaluate("-42").isTrivial)
        #expect(try calc.evaluate("e").isTrivial)
        #expect(try !calc.evaluate("pi").isTrivial)
        #expect(try !calc.evaluate("1+1").isTrivial)
        #expect(try calc.evaluate("2+2=").value == 4)
        #expect(try !calc.evaluate("0xFF").isTrivial)
        #expect(try !calc.evaluate("255 in hex").isTrivial)
    }

    @Test func errors() {
        #expect(throws: CalcError.divisionByZero) { try calc.evaluate("1/0") }
        #expect(throws: CalcError.divisionByZero) { try calc.evaluate("5 % 0") }
        #expect(throws: CalcError.unexpectedEnd) { try calc.evaluate("2+") }
        #expect(throws: CalcError.unexpectedEnd) { try calc.evaluate("(1+2") }
        #expect(throws: CalcError.unexpectedToken(")")) { try calc.evaluate("1+2)") }
        #expect(throws: CalcError.unknownFunction("foo")) { try calc.evaluate("foo(2)") }
        #expect(throws: CalcError.unknownIdentifier("bar")) { try calc.evaluate("bar + 1") }
        #expect(throws: CalcError.domain("sqrt")) { try calc.evaluate("sqrt(-1)") }
        #expect(throws: CalcError.domain("ln")) { try calc.evaluate("ln(0)") }
        #expect(throws: CalcError.argumentCount("pow", expected: "2 arguments")) { try calc.evaluate("pow(2)") }
        #expect(throws: CalcError.invalidNumber("0x")) { try calc.evaluate("0x") }
        #expect(throws: CalcError.empty) { try calc.evaluate("   ") }
        #expect(throws: CalcError.unexpectedToken("$")) { try calc.evaluate("2 $ 3") }
        #expect(throws: CalcError.overflow) { try calc.evaluate("171!") }
        #expect(throws: CalcError.domain("!")) { try calc.evaluate("(-1)!") }
    }

    @Test func randomFunctions() throws {
        let fixed = Calculator(random: { 0.5 })
        #expect(try fixed.evaluate("rand()").value == 0.5)
        #expect(try fixed.evaluate("randi(10)").value == 5)
        let r = try calc.evaluate("randi(6)").value
        #expect(r >= 0 && r < 6 && r == r.rounded())
    }
}

// MARK: - Unit conversion

@Suite struct UnitConverterTests {
    func convert(_ s: String) -> Double? { UnitConverter.convert(s)?.result }
    func close(_ a: Double?, _ b: Double, _ eps: Double = 1e-6) -> Bool {
        guard let a else { return false }
        return abs(a - b) <= eps * max(1, abs(b))
    }

    @Test func length() {
        #expect(close(convert("10 km to mi"), 6.213711922))
        #expect(close(convert("10 km in mi"), 6.213711922))
        #expect(close(convert("1 mi to m"), 1609.344))
        #expect(close(convert("12 in to ft"), 1))
        #expect(close(convert("10 in in cm"), 25.4))
        #expect(close(convert("5ft to cm"), 152.4))
    }

    @Test func temperature() {
        #expect(close(convert("100 c to f"), 212))
        #expect(close(convert("32 °F to °C"), 0))
        #expect(close(convert("-40 f in c"), -40))
        #expect(close(convert("0 k to c"), -273.15))
        #expect(close(convert("98.6 fahrenheit to celsius"), 37))
    }

    @Test func otherCategories() {
        #expect(close(convert("1 kg to lb"), 2.20462262))
        #expect(close(convert("1 gal to l"), 3.785411784))
        #expect(close(convert("1 ha to m2"), 10_000))
        #expect(close(convert("5 sq m to sqft"), 53.8195520835))
        #expect(close(convert("100 km/h to mph"), 62.1371192))
        #expect(close(convert("1.5 GiB to MB"), 1610.612736))
        #expect(close(convert("1 GB to Mb"), 8000))
        #expect(close(convert("100 mb to gb"), 0.1))
        #expect(close(convert("90 min to h"), 1.5))
        #expect(close(convert("2 weeks to days"), 14))
        #expect(close(convert("180 deg to rad"), .pi))
        #expect(close(convert("1 atm to psi"), 14.6959488))
        #expect(close(convert("1 kWh to J"), 3_600_000))
        #expect(close(convert("1 hp to W"), 745.699872))
    }

    @Test func rejectsMismatches() {
        #expect(convert("10 km to kg") == nil)
        #expect(convert("ten km to mi") == nil)
        #expect(convert("10 to mi") == nil)
        #expect(convert("hello world") == nil)
        #expect(convert("10 zorks to mi") == nil)
    }

    @Test func suggestionsWithoutTarget() {
        let s = UnitConverter.suggestions("10 km")
        #expect(s.contains { $0.to.symbol == "mi" })
        #expect(!s.contains { $0.to.symbol == "km" })
        #expect(UnitConverter.suggestions("10").isEmpty)
    }

    @Test func formatting() {
        #expect(UnitConverter.format(6.21371192237334) == "6.213711922")
        #expect(UnitConverter.format(1500) == "1500")
        #expect(UnitConverter.format(0) == "0")
    }
}

// MARK: - Fuzzy matching

@Suite struct FuzzyMatcherTests {
    func s(_ q: String, _ c: String) -> Double? { FuzzyMatcher.score(q, c) }

    @Test func tiersOrder() throws {
        let exact = try #require(s("safari", "Safari"))
        let prefix = try #require(s("saf", "Safari"))
        let wordStart = try #require(s("studio", "Visual Studio Code"))
        let acronym = try #require(s("vsc", "Visual Studio Code"))
        let substring = try #require(s("isua", "Visual Studio Code"))
        let subsequence = try #require(s("vscde", "Visual Studio Code"))
        #expect(exact > prefix)
        #expect(prefix > wordStart)
        #expect(wordStart > acronym)
        #expect(acronym > substring)
        #expect(substring > subsequence)
    }

    @Test func caseAndDiacritics() {
        #expect(s("CAFE", "Café Menu") != nil)
        #expect(s("résumé", "Resume.pdf") != nil)
    }

    @Test func camelCaseAcronym() {
        #expect(s("pt", "PowerToys") != nil)
        #expect((s("pt", "PowerToys") ?? 0) >= FuzzyMatcher.acronym - 40)
    }

    @Test func multiWord() {
        #expect(s("code vis", "Visual Studio Code") != nil)
        #expect(s("code zebra", "Visual Studio Code") == nil)
        #expect((s("visual studio", "Visual Studio Code") ?? 0) > (s("code vis", "Visual Studio Code") ?? 0))
    }

    @Test func noMatch() {
        #expect(s("xyz", "Safari") == nil)
        #expect(s("safarix", "Safari") == nil)
    }

    @Test func shorterCandidatesRankHigherForSamePrefix() {
        #expect((s("term", "Terminal") ?? 0) > (s("term", "Terminal Velocity Extreme Edition") ?? 0))
    }

    @Test func keywordsWeighLess() {
        let title = FuzzyMatcher.best("chrome", title: "Google Chrome") ?? 0
        let viaKeyword = FuzzyMatcher.best("chrome", title: "Browser", keywords: ["Chrome"]) ?? 0
        #expect(viaKeyword < FuzzyMatcher.exact)
        #expect(title > 0)
    }
}

// MARK: - Script headers

@Suite struct ScriptMetadataTests {
    @Test func mactoysHeader() {
        let text = """
        #!/bin/zsh
        # @mactoys.title Say Hello
        # @mactoys.subtitle Greets someone
        # @mactoys.icon hand.wave.fill
        # @mactoys.mode output
        # @mactoys.argument Name (optional)
        # @mactoys.keywords greet, hi
        echo hi
        """
        let m = ScriptMetadata.parse(text, fileName: "say-hello.sh")
        #expect(m.title == "Say Hello")
        #expect(m.subtitle == "Greets someone")
        #expect(m.icon == "hand.wave.fill")
        #expect(m.mode == .output)
        #expect(m.argument == "Name")
        #expect(m.argumentOptional)
        #expect(m.keywords == ["greet", "hi"])
        #expect(m.hasHeader)
    }

    @Test func raycastHeader() {
        let text = """
        #!/usr/bin/env python3
        # Required parameters:
        # @raycast.schemaVersion 1
        # @raycast.title Search Issues
        # @raycast.mode fullOutput
        # @raycast.packageName Developer Utils
        # @raycast.icon 🐞
        # @raycast.argument1 { "type": "text", "placeholder": "Query", "optional": false }
        # @raycast.needsConfirmation true
        """
        let m = ScriptMetadata.parse(text, fileName: "issues.py")
        #expect(m.title == "Search Issues")
        #expect(m.mode == .output)
        #expect(m.subtitle == "Developer Utils")
        #expect(m.icon == "🐞")
        #expect(m.argument == "Query")
        #expect(!m.argumentOptional)
        #expect(m.needsConfirmation)
    }

    @Test func modesAndRefresh() {
        #expect(ScriptMetadata.parse("# @raycast.mode compact", fileName: "a").mode == .silent)
        #expect(ScriptMetadata.parse("# @mactoys.mode terminal", fileName: "a").mode == .terminal)
        let inline = ScriptMetadata.parse("# @mactoys.mode inline\n# @mactoys.refresh 5m", fileName: "a")
        #expect(inline.mode == .inline)
        #expect(inline.refreshInterval == 300)
        #expect(ScriptMetadata.parse("# @mactoys.mode inline", fileName: "a").refreshInterval == 60)
        #expect(ScriptMetadata.interval("1h") == 3600)
        #expect(ScriptMetadata.interval("30") == 30)
        #expect(ScriptMetadata.interval("x") == nil)
    }

    @Test func otherCommentStyles() {
        #expect(ScriptMetadata.parse("// @mactoys.title JS Tool", fileName: "a.js").title == "JS Tool")
        #expect(ScriptMetadata.parse("-- @mactoys.title Lua Tool", fileName: "a.lua").title == "Lua Tool")
    }

    @Test func fallsBackToFileName() {
        let m = ScriptMetadata.parse("#!/bin/sh\necho hi", fileName: "open-my_project.sh")
        #expect(m.title == "Open My Project")
        #expect(!m.hasHeader)
        #expect(m.mode == .output)
        #expect(m.argument == nil)
    }

    @Test func ignoresMetadataInCode() {
        let m = ScriptMetadata.parse("#!/bin/sh\necho '@mactoys.title Nope'", fileName: "real.sh")
        #expect(m.title == "Real")
    }
}

// MARK: - Time parsing

@Suite struct TimeQueryTests {
    @Test func keywords() {
        #expect(TimeQuery.parse("time", scoped: false) == .now(.time))
        #expect(TimeQuery.parse("now", scoped: false) == .now(.time))
        #expect(TimeQuery.parse("date", scoped: false) == .now(.date))
        #expect(TimeQuery.parse("unix", scoped: false) == .now(.unix))
        #expect(TimeQuery.parse("week", scoped: false) == .now(.week))
        #expect(TimeQuery.parse("iso", scoped: false) == .now(.iso))
        #expect(TimeQuery.parse("", scoped: true) == .now(.all))
        #expect(TimeQuery.parse("", scoped: false) == nil)
    }

    @Test func globalNeedsCompleteFirstWord() {
        #expect(TimeQuery.parse("timer", scoped: false) == nil)
        #expect(TimeQuery.parse("tim", scoped: false) == nil)
        #expect(TimeQuery.parse("time machine", scoped: false) == nil)
        #expect(TimeQuery.parse("1792852868", scoped: false) == nil)
        #expect(TimeQuery.parse("london", scoped: false) == nil)
    }

    @Test func unixTimestamps() {
        #expect(TimeQuery.parse("unix 1792852868", scoped: false) == .instant(Date(timeIntervalSince1970: 1_792_852_868)))
        #expect(TimeQuery.parse("epoch 0", scoped: false) == .instant(Date(timeIntervalSince1970: 0)))
        #expect(TimeQuery.parse("1792852868", scoped: true) == .instant(Date(timeIntervalSince1970: 1_792_852_868)))
        #expect(TimeQuery.parse("1792852868123", scoped: true) == .instant(Date(timeIntervalSince1970: 1_792_852_868.123)))
    }

    @Test func zones() {
        guard case .zone(let tz, let label)? = TimeQuery.parse("time in London", scoped: false) else {
            Issue.record("expected a zone")
            return
        }
        #expect(tz.identifier == "Europe/London")
        #expect(label == "London")
        if case .zone(let tokyo, _)? = TimeQuery.parse("tokyo time", scoped: false) {
            #expect(tokyo.identifier == "Asia/Tokyo")
        } else { Issue.record("tokyo time") }
        if case .zone(let ny, _)? = TimeQuery.parse("time new york", scoped: false) {
            #expect(ny.identifier == "America/New_York")
        } else { Issue.record("time new york") }
        if case .zone(let sf, _)? = TimeQuery.parse("time in san francisco", scoped: false) {
            #expect(sf.identifier == "America/Los_Angeles")
        } else { Issue.record("san francisco") }
        if case .zone(let off, let l)? = TimeQuery.parse("utc+5:30", scoped: false) {
            #expect(off.secondsFromGMT() == 19_800)
            #expect(l == "UTC+5:30")
        } else { Issue.record("utc+5:30") }
        if case .zone(let utc, _)? = TimeQuery.parse("utc", scoped: false) {
            #expect(utc.secondsFromGMT() == 0)
        } else { Issue.record("utc") }
    }

    @Test func datesAndWeeks() throws {
        let utc = try #require(TimeZone(identifier: "UTC"))
        let d = try #require(DateParsing.parse("2026-10-24T14:41:08Z"))
        #expect(d == Date(timeIntervalSince1970: 1_792_852_868))
        #expect(TimeQuery.parse("week::2026-10-24T14:41:08Z", scoped: false) == .week(d))
        #expect(TimeQuery.parse("unix::2026-10-24T14:41:08Z", scoped: false) == .unixOf(d))
        let w = TimeFormats.isoWeek(d, in: utc)
        #expect(w.week == 43)
        #expect(w.of == 53)      // 2026 has 53 ISO weeks
        #expect(TimeFormats.isoWeek(try #require(DateParsing.parse("2027-01-01T12:00:00Z")), in: utc).week == 53)
        #expect(DateParsing.parse("not a date") == nil)
        #expect(DateParsing.parse("2026-10-24", timeZone: utc) == Date(timeIntervalSince1970: 1_792_800_000))
    }

    @Test func formatRows() throws {
        let tz = try #require(TimeZone(identifier: "Asia/Shanghai"))
        let d = Date(timeIntervalSince1970: 1_792_852_868)
        let rows = TimeFormats.rows(for: d, zone: tz, locale: Locale(identifier: "en_GB"))
        func row(_ l: String) -> String? { rows.first { $0.label == l }?.value }
        #expect(row("ISO 8601") == "2026-10-24T22:41:08+08:00")
        #expect(row("Unix") == "1792852868")
        #expect(row("Week") == "43 of 53")
        #expect(row("UTC") == "14:41:08")
        #expect(row("Day of year") == "297 of 365")
    }

    @Test func offsetsAndDifferences() throws {
        let d = Date(timeIntervalSince1970: 1_792_852_868)
        let shanghai = try #require(TimeZone(identifier: "Asia/Shanghai"))
        let london = try #require(TimeZone(identifier: "Europe/London"))
        let kolkata = try #require(TimeZone(identifier: "Asia/Kolkata"))
        #expect(TimeFormats.offsetLabel(28_800) == "UTC+8")
        #expect(TimeFormats.offsetLabel(-16_200) == "UTC−4:30")
        let en = Locale(identifier: "en_US")
        #expect(TimeFormats.difference(london, from: shanghai, at: d, locale: en) == "7 hours behind")   // BST until 25 Oct
        #expect(TimeFormats.difference(kolkata, from: shanghai, at: d, locale: en) == "2 hr, 30 min behind")
        #expect(TimeFormats.difference(shanghai, from: shanghai, at: d, locale: en) == "same time")
    }

    @Test func customFormats() throws {
        let custom = TimeFormats.Custom.parse("Short=dd.MM.yy\nStamp=UTC:HH:mm\nbroken\nUnix=UXT")
        #expect(custom.count == 3)
        #expect(custom[1].utc)
        let tz = try #require(TimeZone(identifier: "Asia/Shanghai"))
        let d = Date(timeIntervalSince1970: 1_792_852_868)
        #expect(TimeFormats.format(d, pattern: "dd.MM.yy", zone: tz, locale: Locale(identifier: "en_US_POSIX")) == "24.10.26")
        #expect(TimeFormats.format(d, pattern: "UXT", zone: tz, locale: Locale(identifier: "en_US_POSIX")) == "1792852868")
        #expect(TimeFormats.format(d, pattern: "'W'WOY", zone: tz, locale: Locale(identifier: "en_US_POSIX")) == "W43")
    }
}

// MARK: - Value generator and keywords

@Suite struct ValueGeneratorTests {
    func values(_ s: String) -> [String] {
        guard case .success(let out)? = ValueGenerator.generate(s) else { return [] }
        return out.map(\.value)
    }

    @Test func hashes() {
        #expect(values("md5 abc") == ["900150983cd24fb0d6963f7d28e17f72"])
        #expect(values("sha1 abc") == ["a9993e364706816aba3e25717850c26c9cd0d89d"])
        #expect(values("sha256 abc") == ["ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad"])
        #expect(values("hash abc").count == 4)
    }

    @Test func uuids() throws {
        let v4 = try #require(values("uuid").first)
        #expect(v4.count == 36)
        #expect(Array(v4)[14] == "4")
        let v7 = try #require(values("uuidv7").first)
        #expect(Array(v7)[14] == "7")
        #expect("89ab".contains(Array(v7)[19]))
        #expect(Array(try #require(values("guid1").first))[14] == "1")
        #expect(values("uuid 3").count == 3)
        #expect(values("uuidv3 ns:DNS python.org") == ["6fa459ea-ee8a-3ca4-894e-db77e160355e"])
        #expect(values("uuidv5 ns:DNS python.org") == ["886313e1-3b8a-5372-9b90-0c9aee199e5d"])
        #expect(values("uuid5 ns:URL https://example.com") == ["4fd35a71-71ef-5a55-a9d9-aa75c889a6d0"])
        guard case .failure? = ValueGenerator.generate("uuidv5 ns:NOPE x") else { Issue.record("bad namespace"); return }
    }

    @Test func uuidV7IsTimeOrdered() {
        let a = ValueGenerator.uuid(version: 7, now: Date(timeIntervalSince1970: 1_000))
        let b = ValueGenerator.uuid(version: 7, now: Date(timeIntervalSince1970: 2_000))
        #expect(a.uuidString.prefix(13) < b.uuidString.prefix(13))
    }

    @Test func encodings() {
        #expect(values("base64 hello") == ["aGVsbG8="])
        #expect(values("base64d aGVsbG8=") == ["hello"])
        #expect(values("base64d aGVsbG8") == ["hello"])
        #expect(values("url a b&c") == ["a+b%26c"])
        #expect(values("urld a+b%26c") == ["a b&c"])
        #expect(values("esc:data C:\\Program Files") == ["C%3A%5CProgram%20Files"])
        #expect(values("uesc:data C%3A%5CProgram%20Files") == ["C:\\Program Files"])
        #expect(values("esc:hex z") == ["%7A"])
        #expect(values("uesc:hex %7A") == ["z"])
        #expect(ValueGenerator.generate("hello world") == nil)
    }
}

@Suite struct KeywordParserTests {
    let entries = [KeywordParser.Entry(target: "calc", keyword: "="), KeywordParser.Entry(target: "web", keyword: "??"),
                   KeywordParser.Entry(target: "help", keyword: "?"), KeywordParser.Entry(target: "clipboard", keyword: "cb"),
                   KeywordParser.Entry(target: "url", keyword: "//"), KeywordParser.Entry(target: "none", keyword: "")]

    @Test func symbolicKeywordsAreDirect() {
        #expect(KeywordParser.match("=2+2", entries) == .init(target: "calc", keyword: "=", rest: "2+2"))
        #expect(KeywordParser.match("= 2+2", entries) == .init(target: "calc", keyword: "=", rest: "2+2"))
        #expect(KeywordParser.match("// apple.com", entries)?.target == "url")
    }

    @Test func longestWins() {
        #expect(KeywordParser.match("?? weather", entries) == .init(target: "web", keyword: "??", rest: "weather"))
        #expect(KeywordParser.match("? x", entries)?.target == "help")
    }

    @Test func wordKeywordsNeedASpace() {
        #expect(KeywordParser.match("cb invoice", entries) == .init(target: "clipboard", keyword: "cb", rest: "invoice"))
        #expect(KeywordParser.match("cb", entries)?.target == "clipboard")
        #expect(KeywordParser.match("CB x", entries)?.target == "clipboard")
        #expect(KeywordParser.match("cbr", entries) == nil)
        #expect(KeywordParser.match("safari", entries) == nil)
    }

    @Test func directAliasesOverride() {
        let e = [KeywordParser.Entry(target: "files", keyword: "f", direct: true)]
        #expect(KeywordParser.match("freport", e) == .init(target: "files", keyword: "f", rest: "report"))
    }
}

@Suite struct DetectionTests {
    @Test func urls() {
        #expect(URLDetection.url(from: "apple.com")?.absoluteString == "https://apple.com")
        #expect(URLDetection.url(from: "github.com/microsoft/PowerToys")?.host == "github.com")
        #expect(URLDetection.url(from: "https://example.org/x?y=1")?.absoluteString == "https://example.org/x?y=1")
        #expect(URLDetection.url(from: "localhost:3000")?.absoluteString == "http://localhost:3000")
        #expect(URLDetection.url(from: "192.168.1.1")?.absoluteString == "http://192.168.1.1")
        #expect(URLDetection.url(from: "mailto:someone@example.com")?.scheme == "mailto")
        #expect(URLDetection.url(from: "report.pdf") == nil)
        #expect(URLDetection.url(from: "hello world.com") == nil)
        #expect(URLDetection.url(from: "time") == nil)
        #expect(URLDetection.url(from: "1.5") == nil)
    }

    @Test func appArguments() {
        let split = AppIndexer.splitArguments("Visual Studio Code -- /tmp/project")
        #expect(split?.name == "Visual Studio Code")
        #expect(split?.arguments == ["/tmp/project"])
        #expect(AppIndexer.splitArguments("code -d a b")?.arguments == ["-d", "a", "b"])
        #expect(AppIndexer.splitArguments("visual studio code") == nil)
    }

    @Test func processList() {
        let list = ProcessEntry.parse("  123  1.5  2048 alice /Applications/Safari.app/Contents/MacOS/Safari\nbad line\n 7 0.0 16 root /sbin/launchd")
        #expect(list.count == 2)
        #expect(list[0].pid == 123)
        #expect(list[0].memory == 2048 * 1024)
        #expect(list[0].name == "Safari")
        #expect(list[1].user == "root")
    }
}

// MARK: - Result merging and usage ranking

@MainActor
private final class FakeProvider: SearchProvider {
    let id: String
    let name: String
    let summary = "Fake"
    let icon = ItemIcon.symbol("star", .blue)
    let defaultKeyword = ""
    var delay: UInt64
    var results: (String) -> [PaletteItem]

    init(_ id: String, delay: UInt64 = 0, results: @escaping (String) -> [PaletteItem]) {
        self.id = id
        self.name = id.capitalized
        self.delay = delay
        self.results = results
    }

    func search(_ query: SearchQuery) async -> [PaletteItem] {
        if delay > 0 { try? await Task.sleep(nanoseconds: delay) }
        return results(query.text)
    }
}

@MainActor
private func item(_ id: String, _ provider: String, score: Double, fallback: Bool = false, section: String? = nil) -> PaletteItem {
    PaletteItem(id: id, title: id, icon: .symbol("star", .blue), providerID: provider, section: section, score: score,
                primary: PaletteAction(id: "run", title: "Run", symbol: "play") { .stay }, isFallback: fallback)
}

@MainActor
@Suite struct SearchSessionTests {
    /// Runs a search and waits until every provider answered.
    func run(_ session: SearchSession, _ providers: [any SearchProvider], text: String) async -> [ResultSection] {
        await withCheckedContinuation { cont in
            var done = false
            session.onUpdate = { sections, pending in
                guard !pending, !done else { return }
                done = true
                cont.resume(returning: sections)
            }
            session.run(providers.map { SearchSession.Source(provider: $0, query: SearchQuery(text: text, scoped: false, frontEnd: .palette)) })
        }
    }

    @Test func sectionsOrderedByBestMatchAndFallbackLast() async {
        let session = SearchSession(layout: .sections(maxPerSection: 2), usage: UsageStore(file: nil))
        session.sectionTitle = { $0.providerID }
        let a = FakeProvider("apps") { _ in [item("apps:1", "apps", score: 500), item("apps:2", "apps", score: 400), item("apps:3", "apps", score: 300)] }
        let b = FakeProvider("time", delay: 20_000_000) { _ in [item("time:1", "time", score: 990)] }
        let w = FakeProvider("web") { _ in [item("web:1", "web", score: 1, fallback: true)] }
        let sections = await run(session, [w, a, b], text: "x")
        #expect(sections.map(\.title) == ["time", "apps", "web"])
        #expect(sections[1].items.map(\.id) == ["apps:1", "apps:2"])   // capped per section
    }

    @Test func duplicatesKeepTheHigherScore() async {
        let session = SearchSession(layout: .flat(limit: 10), usage: UsageStore(file: nil))
        let a = FakeProvider("a") { _ in [item("same", "a", score: 100)] }
        let b = FakeProvider("b") { _ in [item("same", "b", score: 700)] }
        let sections = await run(session, [a, b], text: "x")
        #expect(sections.first?.items.count == 1)
        #expect(sections.first?.items.first?.providerID == "b")
    }

    @Test func flatLayoutLimitsAndSorts() async {
        let session = SearchSession(layout: .flat(limit: 2), usage: UsageStore(file: nil))
        let a = FakeProvider("a") { _ in [item("1", "a", score: 1), item("2", "a", score: 3), item("3", "a", score: 2)] }
        let sections = await run(session, [a], text: "x")
        #expect(sections.first?.items.map(\.id) == ["2", "3"])
    }

    @Test func usageBoostReordersResults() async {
        let usage = UsageStore(file: nil)
        let session = SearchSession(layout: .flat(limit: 10), usage: usage)
        let a = FakeProvider("a") { _ in [item("often", "a", score: 600), item("top", "a", score: 650)] }
        for _ in 0..<8 { usage.record(item("often", "a", score: 0), query: "x") }
        let sections = await run(session, [a], text: "x")
        #expect(sections.first?.items.first?.id == "often")
        session.boostWeight = 0
        let plain = await run(session, [a], text: "x")
        #expect(plain.first?.items.first?.id == "top")
    }

    @Test func newerSearchWins() async {
        let session = SearchSession(layout: .flat(limit: 10), usage: UsageStore(file: nil))
        let slow = FakeProvider("a", delay: 60_000_000) { q in [item("result:\(q)", "a", score: 1)] }
        session.run([SearchSession.Source(provider: slow, query: SearchQuery(text: "old", scoped: false, frontEnd: .palette))])
        let sections = await run(session, [slow], text: "new")
        #expect(sections.first?.items.map(\.id) == ["result:new"])
    }
}

@MainActor
@Suite struct UsageStoreTests {
    @Test func historyAndBoost() {
        let usage = UsageStore(file: nil)
        let a = item("apps:a", "apps", score: 0), b = item("apps:b", "apps", score: 0)
        #expect(usage.boost("apps:a") == 0)
        usage.record(a, query: "a")
        usage.record(b, query: "b")
        usage.record(a, query: "a again")
        #expect(usage.history.map(\.id) == ["apps:a", "apps:b"])
        #expect(usage.history.first?.query == "a again")
        #expect(usage.boost("apps:a") > usage.boost("apps:b"))
        let old = Date().addingTimeInterval(-30 * 86400)
        usage.record(item("apps:c", "apps", score: 0), query: "c", at: old)
        #expect(usage.boost("apps:c") < usage.boost("apps:b"))
        usage.remove("apps:a")
        #expect(!usage.history.contains { $0.id == "apps:a" })
        #expect(usage.boost("apps:a") == 0)
    }

    @Test func persistsToDisk() throws {
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("usage-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: file) }
        let usage = UsageStore(file: file)
        usage.record(item("calc:1+1", "calc", score: 0), query: "1+1")
        usage.recordShell("ls -la")
        usage.flush()
        let reloaded = UsageStore(file: file)
        #expect(reloaded.history.first?.id == "calc:1+1")
        #expect(reloaded.shellHistory == ["ls -la"])
    }

    @Test func settingsRoundTrip() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = SettingsStore(directory: dir)
        var s = CommandPaletteSettings()
        s.pins.append(PinnedCommand(id: "calc:page", title: "Calc", icon: .emoji("🧮")))
        s.aliases.append(CommandAlias(alias: "x", target: "apps:/Applications/Safari.app", title: "Safari", direct: false))
        s.hotkeys.append(CommandHotkey(target: "system:lock", title: "Lock", icon: .symbol("lock.fill", .indigo), shortcut: Shortcut(37, [.control, .option])))
        s.providers["files"] = ProviderToggle(enabled: false, global: false)
        store.save(s, id: "cmdpal")
        #expect(store.load("cmdpal", default: CommandPaletteSettings()) == s)
        var r = RunSettings()
        r.plugins["calc"] = PluginSetting(enabled: true, keyword: "calc", global: false)
        store.save(r, id: "run")
        #expect(store.load("run", default: RunSettings()) == r)
    }
}

// MARK: - Providers

@MainActor
@Suite struct ProviderTests {
    func query(_ text: String, scoped: Bool = false) -> SearchQuery { SearchQuery(text: text, scoped: scoped, frontEnd: .palette) }

    @Test func calculatorSkipsTrivialGlobalInput() async throws {
        let calc = try #require(LauncherEngine.shared.provider("calc"))
        #expect(await calc.search(query("42")).isEmpty)
        #expect(await calc.search(query("safari")).isEmpty)
        #expect(await calc.search(query("2+")).isEmpty)
        let results = await calc.search(query("2+2"))
        #expect(results.first?.title == "4")
        #expect(results.first?.primary.title == "Copy")
        let scoped = await calc.search(query("2+", scoped: true))
        #expect(scoped.first?.title == "Invalid expression")
        let hex = await calc.search(query("255 in hex"))
        #expect(hex.first?.title == "0xFF")
    }

    @Test func systemSettingsSearch() async throws {
        let settings = try #require(LauncherEngine.shared.provider("settings"))
        let displays = await settings.search(query("displays"))
        #expect(displays.first?.title == "Displays")
        let privacy = await settings.search(query("privacy>cam", scoped: true))
        #expect(privacy.contains { $0.title == "Camera" })
        let general = await settings.search(query("general:", scoped: true))
        #expect(general.contains { $0.title == "Date & Time" })
        #expect(!general.contains { $0.title == "Displays" })
        #expect(SystemSettingsProvider.panes.allSatisfy { $0.url != nil })
    }

    @Test func timeKeywordNeedsWholeWord() async throws {
        let time = try #require(LauncherEngine.shared.provider("time"))
        #expect(await time.search(query("tim")).isEmpty)
        let now = await time.search(query("time"))
        #expect(now.first?.accessory == "Copy")
        let unix = await time.search(query("unix 1792852868"))
        #expect(unix.contains { $0.title == "2026-10-24T14:41:08Z" || $0.subtitle == "ISO 8601" })
    }

    @Test func unitsAndValues() async throws {
        let units = try #require(LauncherEngine.shared.provider("units"))
        #expect(await units.search(query("10 km to mi")).first?.title == "6.213711922 mi")
        let values = try #require(LauncherEngine.shared.provider("values"))
        #expect(await values.search(query("md5 abc")).first?.title == "900150983cd24fb0d6963f7d28e17f72")
        #expect(await values.search(query("hello")).isEmpty)
    }

    @Test func scriptFolderScan() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("scripts-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let script = dir.appendingPathComponent("hello.sh")
        try "#!/bin/zsh\n# @mactoys.title Hello There\n# @mactoys.mode silent\necho hi\n".write(to: script, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: script.path)
        try "just notes".write(to: dir.appendingPathComponent("notes.txt"), atomically: true, encoding: .utf8)
        try "#!/usr/bin/env python3\nprint('x')\n".write(to: dir.appendingPathComponent("not-executable.py"), atomically: true, encoding: .utf8)
        let found = ScriptLibrary.scan(dir)
        #expect(found.map(\.meta.title) == ["Hello There", "Not Executable"])
        #expect(found.first?.meta.mode == .silent)
        let example = ScriptMetadata.parse(ScriptLibrary.example, fileName: "say-hello.sh")
        #expect(example.title == "Say Hello")
        #expect(example.argument == "Name")
        #expect(example.argumentOptional)
    }

    @Test func scriptRunsWithArgument() async throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("scripts-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("greet.sh")
        try "#!/bin/sh\necho \"Hello, $1!\"\n".write(to: url, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
        let s = try #require(ScriptLibrary.scan(dir).first)
        let out = await ScriptLibrary.execute(s, argument: "Ada; rm -rf /")
        #expect(out.ok)
        #expect(out.text == "Hello, Ada; rm -rf /!")
    }

    @Test func chromiumBookmarksParse() throws {
        let json = """
        {"roots":{"bookmark_bar":{"name":"Bookmarks bar","type":"folder","children":[
          {"name":"PowerToys","type":"url","url":"https://github.com/microsoft/PowerToys"},
          {"name":"Work","type":"folder","children":[{"name":"","type":"url","url":"https://example.com/"}]}]}}}
        """
        let obj = try JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any]
        let roots = try #require(obj?["roots"] as? [String: Any])
        var out: [Bookmark] = []
        for (_, node) in roots { BookmarkReader.walkChromium(node, folder: "", browser: .chrome, into: &out) }
        #expect(out.count == 2)
        #expect(out[0].title == "PowerToys")
        #expect(out[0].folder == "Bookmarks bar")
        #expect(out[1].title == "https://example.com/")
        #expect(out[1].folder == "Bookmarks bar › Work")
    }

    @Test func editorHistoryParse() {
        let json = """
        {"entries":[{"folderUri":"file:///Users/ada/src/mactoys"},{"fileUri":"file:///Users/ada/notes.md"},
        {"folderUri":"vscode-remote://ssh-remote%2Bbox/home/ada/app","remoteAuthority":"ssh-remote+box"},
        {"workspace":{"id":"1","configPath":"file:///Users/ada/w.code-workspace"}}]}
        """
        let list = EditorHistory.parse(Data(json.utf8), editor: .vscode)
        #expect(list.map(\.kind) == [.folder, .file, .folder, .workspace])
        #expect(list[0].name == "mactoys")
        #expect(list[2].remote == "ssh-remote+box")
    }
}
