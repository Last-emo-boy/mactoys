import Foundation
import MacToysCore
import Testing
@testable import TextActions

@Suite struct TextActionsTests {
    // MARK: Relevance

    private func actions(_ text: String, _ context: SelectionContext = SelectionContext()) -> Set<BuiltInAction> {
        let a = SelectionAnalysis(text)
        return Set(BuiltInAction.allCases.filter { ActionRelevance.applies($0, a, context) })
    }

    @Test func linksShowOpenLinkAndMarkdownLink() {
        let found = actions("https://developer.apple.com/documentation/translation")
        #expect(found.contains(.openLink))
        #expect(found.contains(.markdownLink))
        #expect(found.contains(.copy))
        #expect(!found.contains(.calculate))
        #expect(!found.contains(.translate))
        #expect(!found.contains(.cut))

        let bare = SelectionAnalysis("see apple.com/mac for details")
        #expect(bare.links.first?.host == "apple.com")
        #expect(bare.wholeLink == nil)
    }

    @Test func emailsShowEmailNotOpenLink() {
        let a = SelectionAnalysis("Write to mara.sato@example.com today")
        #expect(a.emails == ["mara.sato@example.com"])
        #expect(a.links.isEmpty)
        let found = actions("mara.sato@example.com")
        #expect(found.contains(.email))
        #expect(!found.contains(.openLink))
    }

    @Test func pathsNeedToExist() {
        let a = SelectionAnalysis("~/Documents/Notes.txt")
        #expect(a.pathCandidate == NSHomeDirectory() + "/Documents/Notes.txt")
        #expect(SelectionAnalysis("/Users/me/My\\ File.txt").pathCandidate == "/Users/me/My File.txt")
        #expect(SelectionAnalysis("file:///tmp/report.pdf").pathCandidate == "/tmp/report.pdf")
        #expect(SelectionAnalysis("'/Applications/Safari.app'").pathCandidate == "/Applications/Safari.app")
        #expect(SelectionAnalysis("and/or").pathCandidate == nil)
        #expect(SelectionAnalysis("/usr/bin\n/bin").pathCandidate == nil)
        #expect(actions("/tmp", SelectionContext(pathExists: true)).contains(.revealPath))
        #expect(!actions("/tmp/nope", SelectionContext(pathExists: false)).contains(.revealPath))
    }

    @Test func expressionsShowCalculate() {
        #expect(actions("1,280 × 0.85 + 64").contains(.calculate))
        #expect(actions("sqrt(2) * 100").contains(.calculate))
        #expect(!actions("2026").contains(.calculate))
        #expect(!actions("2026-11-04").contains(.calculate))
        #expect(!actions("Chapter 3").contains(.calculate))
    }

    @Test func jsonShowsFormatOrMinify() {
        let compact = actions(#"{"name":"Ada","tags":["math","code"]}"#)
        #expect(compact.contains(.formatJSON))
        #expect(!compact.contains(.minifyJSON))
        #expect(!compact.contains(.translate))
        let pretty = actions("{\n  \"name\": \"Ada\"\n}")
        #expect(pretty.contains(.minifyJSON))
        #expect(!pretty.contains(.formatJSON))
        #expect(!actions("{not json}").contains(.formatJSON))
        #expect(!actions("42").contains(.formatJSON))
    }

    @Test func wordsAndEditing() {
        let word = SelectionAnalysis("serendipity")
        #expect(word.isSingleWord && word.isShortPhrase)
        #expect(actions("serendipity", SelectionContext(hasDefinition: true)).contains(.lookUp))
        #expect(!actions("serendipity").contains(.lookUp))
        #expect(actions("recieve", SelectionContext(isMisspelled: true)).contains(.spelling))
        #expect(!actions("two words", SelectionContext(isMisspelled: true)).contains(.spelling))
        #expect(!actions("Bonjour", SelectionContext(isInTargetLanguage: true)).contains(.translate))
        #expect(actions("Bonjour").contains(.translate))

        let editable = actions("hello", SelectionContext(isEditable: true, clipboardHasText: true))
        #expect(editable.isSuperset(of: [.cut, .copy, .paste, .changeCase, .count, .speak, .search]))
        #expect(!actions("hello").contains(.paste))
        #expect(!actions("12345").contains(.changeCase))
        #expect(actions(String(repeating: "a", count: 501)).contains(.search) == false)
        // Nothing selected: only Paste can apply (click and hold).
        #expect(actions("", SelectionContext(isEditable: true, clipboardHasText: true)) == [.paste])
    }

    @Test func markdownLinkUsesClipboardLinkForText() {
        let url = URL(string: "https://example.com/launch")
        #expect(actions("launch notes", SelectionContext(clipboardURL: url)).contains(.markdownLink))
        #expect(!actions("launch notes").contains(.markdownLink))
        #expect(MarkdownLink.make(selection: "launch [notes]", wholeLink: nil, clipboardURL: url)
                == "[launch \\[notes\\]](https://example.com/launch)")
        #expect(MarkdownLink.make(selection: "https://www.apple.com/mac/", wholeLink: URL(string: "https://www.apple.com/mac/"),
                                  clipboardURL: nil) == "[apple.com/mac](https://www.apple.com/mac/)")
        #expect(MarkdownLink.make(selection: "two\nlines", wholeLink: nil, clipboardURL: url) == nil)
    }

    @Test func customActionConditions() {
        let link = CustomAction(name: "Archive", kind: .url, template: "https://web.archive.org/web/{text}", condition: .link)
        #expect(ActionRelevance.applies(link, SelectionAnalysis("https://example.com"), SelectionContext()))
        #expect(!ActionRelevance.applies(link, SelectionAnalysis("plain words"), SelectionContext()))
        let hex = CustomAction(name: "Color", kind: .shell, script: "cat", condition: .regex, pattern: "^#[0-9a-fA-F]{6}$")
        #expect(ActionRelevance.applies(hex, SelectionAnalysis("#FF5F4A"), SelectionContext()))
        #expect(!ActionRelevance.applies(hex, SelectionAnalysis("#FF5F4"), SelectionContext()))
        let broken = CustomAction(name: "Bad", kind: .shell, script: "cat", condition: .regex, pattern: "(")
        #expect(!ActionRelevance.applies(broken, SelectionAnalysis("anything"), SelectionContext()))
        let incomplete = CustomAction(name: "Empty", kind: .shell)
        #expect(!ActionRelevance.applies(incomplete, SelectionAnalysis("anything"), SelectionContext()))
        let number = CustomAction(name: "Double", kind: .shell, script: "cat", condition: .number)
        #expect(ActionRelevance.applies(number, SelectionAnalysis("1,024"), SelectionContext()))
        #expect(ActionRelevance.applies(number, SelectionAnalysis("3 * 4"), SelectionContext()))
        #expect(!ActionRelevance.applies(number, SelectionAnalysis("four"), SelectionContext()))
    }

    // MARK: Bar items

    @Test func barKeepsUserOrderAndOverflow() {
        var s = TextActionsSettings()
        s.visibleCount = 3
        s.actions = s.slots
        if let i = s.actions.firstIndex(where: { $0.id == "search" }) { s.actions.move(fromOffsets: [i], toOffset: 0) }
        if let i = s.actions.firstIndex(where: { $0.id == "count" }) { s.actions[i].enabled = false }
        let items = BarItems.actions(settings: s, analysis: SelectionAnalysis("hello world"), context: SelectionContext(isEditable: true))
        let ids = items.map(\.id)
        #expect(ids.first == "search")
        #expect(!ids.contains("count"))
        #expect(ids.contains("cut") && !ids.contains("paste"))

        let main = BarItems.page(.main, of: items, visibleCount: 3)
        #expect(main.count == 4 && main.last?.kind == .more)
        let overflow = BarItems.page(.overflow, of: items, visibleCount: 3)
        #expect(overflow.first?.kind == .back)
        #expect(overflow.count == items.count - 3 + 1)
        // One action left over takes the chevron's place.
        #expect(BarItems.page(.main, of: Array(items.prefix(4)), visibleCount: 3).count == 4)
        #expect(BarItems.page(.main, of: Array(items.prefix(4)), visibleCount: 3).last?.kind != .more)
        #expect(BarItems.page(.cases, of: items, visibleCount: 3).count == CaseTransform.allCases.count + 1)
        #expect(BarItems.page(.spelling(["receive", "relieve"]), of: items, visibleCount: 3).map(\.title) == ["Back", "receive", "relieve"])
    }

    @Test func slotsReconcile() {
        let custom = CustomAction(name: "Sort", kind: .shell, script: "sort")
        // An old order missing some built-ins, with an unknown id and a duplicate.
        let stored = [ActionSlot("search"), ActionSlot("bogus"), ActionSlot("copy", enabled: false), ActionSlot("search")]
        let slots = ActionSlot.reconcile(stored, custom: [custom])
        let ids = slots.map(\.id)
        #expect(Set(ids).count == ids.count)
        #expect(!ids.contains("bogus"))
        #expect(ids.count == BuiltInAction.allCases.count + 1)
        #expect(ids.last == custom.slotID)
        #expect(slots.first { $0.id == "copy" }?.enabled == false)
        #expect(ids.firstIndex(of: "search")! < ids.firstIndex(of: "copy")!)
        // Missing built-ins follow their default predecessor.
        #expect(ids.firstIndex(of: "paste") == ids.firstIndex(of: "copy")! + 1)

        var s = TextActionsSettings()
        s.add(custom)
        #expect(s.slots.last?.id == custom.slotID)
        s.remove(customID: custom.id)
        #expect(!s.slots.contains { $0.id == custom.slotID })
        #expect(s.customActions.isEmpty)
    }

    // MARK: Templates and transforms

    @Test func templateEncoding() {
        #expect(URLTemplate.encode("café & crème/?#") == "caf%C3%A9%20%26%20cr%C3%A8me%2F%3F%23")
        #expect(URLTemplate.encode("a-b_c.d~e") == "a-b_c.d~e")
        #expect(URLTemplate.expand("https://www.google.com/search?q={text}", text: "Liquid Glass")?.absoluteString
                == "https://www.google.com/search?q=Liquid%20Glass")
        #expect(URLTemplate.expand("https://x.test/{text}/{text}", text: "a b")?.absoluteString == "https://x.test/a%20b/a%20b")
        #expect(URLTemplate.expand("https://example.com/about", text: "ignored")?.absoluteString == "https://example.com/about")
        #expect(URLTemplate.expand("things:///add?title={text}", text: "Buy milk")?.absoluteString == "things:///add?title=Buy%20milk")
        #expect(URLTemplate.expand("not a url {text}", text: "x") == nil)
        #expect(URLTemplate.expand("", text: "x") == nil)
        #expect(URLTemplate.expand("https://www.baidu.com/s?wd={text}", text: "你好")?.absoluteString
                == "https://www.baidu.com/s?wd=%E4%BD%A0%E5%A5%BD")
        for engine in SearchEngine.allCases where engine != .custom {
            #expect(URLTemplate.isValid(engine.template ?? ""), "\(engine)")
        }
    }

    @Test func caseTransforms() {
        #expect(CaseTransform.upper.apply("Hello, wörld") == "HELLO, WÖRLD")
        #expect(CaseTransform.lower.apply("Hello, WÖRLD") == "hello, wörld")
        #expect(CaseTransform.title.apply("the lord of the rings: the return of the king")
                == "The Lord of the Rings: The Return of the King")
        #expect(CaseTransform.title.apply("NEW IPHONE FEATURES") == "New Iphone Features")
        #expect(CaseTransform.title.apply("what's new in macOS and iPadOS") == "What's New in macOS and iPadOS")
        #expect(CaseTransform.title.apply("a tale of two cities") == "A Tale of Two Cities")
        #expect(CaseTransform.sentence.apply("HELLO THERE. how ARE you? fine!\nnext line")
                == "Hello there. How are you? Fine!\nNext line")
        #expect(CaseTransform.sentence.apply("pi is 3.14 roughly") == "Pi is 3.14 roughly")
        #expect(CaseTransform.camel.apply("user account ID") == "userAccountId")
        #expect(CaseTransform.camel.apply("HTTPServer error-code") == "httpServerErrorCode")
        #expect(CaseTransform.snake.apply("userAccountID") == "user_account_id")
        #expect(CaseTransform.snake.apply("Max Retry Count") == "max_retry_count")
        #expect(CaseTransform.kebab.apply("Release Notes 2026") == "release-notes-2026")
        #expect(CaseTransform.kebab.apply("first line\n  Second Line") == "first-line\n  second-line")
        #expect(CaseTransform.identifierWords("parseJSONValue") == ["parse", "JSON", "Value"])
    }

    @Test func countsWithCJK() {
        let english = TextStats("Hello, world! Don't stop — e-mail me at 3.14 o'clock.")
        #expect(english.words == 9)
        let chinese = TextStats("你好世界")
        #expect(chinese.words == 4)
        #expect(chinese.characters == 4)
        #expect(TextStats("日本語のテキスト").words == 8)
        #expect(TextStats("我爱 Swift 编程").words == 5)
        #expect(TextStats("안녕하세요 세계").words == 2)
        #expect(TextStats("Ünïcödé façade naïve").words == 3)
        #expect(TextStats("well- done").words == 2)

        let emoji = TextStats("👍🏽 ok")
        #expect(emoji.characters == 4)
        #expect(emoji.charactersExcludingSpaces == 3)

        #expect(TextStats("").lines == 0)
        #expect(TextStats("one").lines == 1)
        #expect(TextStats("one\ntwo\n").lines == 2)
        #expect(TextStats("one\r\ntwo\n\nfour").lines == 4)
        #expect(TextStats("a b").charactersExcludingSpaces == 2)
        #expect(TextStats(String(repeating: "word ", count: 460)).readingTime == .seconds(120))
    }

    @Test func jsonFormatAndMinify() {
        let source = #"{"b":1,"a":[true,false,null],"s":"x\"yé","e":{},"n":-1.5e3,"o":{"k":[]}}"#
        let pretty = JSONFormatter.pretty(source)
        #expect(pretty == """
        {
          "b": 1,
          "a": [
            true,
            false,
            null
          ],
          "s": "x\\"yé",
          "e": {},
          "n": -1.5e3,
          "o": {
            "k": []
          }
        }
        """)
        #expect(JSONFormatter.minify(pretty ?? "") == source)
        #expect(JSONFormatter.minify("  [ 1 , 2 ,\n 3 ]  ") == "[1,2,3]")
        #expect(JSONFormatter.pretty("[]") == "[]")
        #expect(JSONFormatter.pretty(#"{"emoji":"😀 你好"}"#, indent: 4) == "{\n    \"emoji\": \"😀 你好\"\n}")
        for invalid in ["{", "[1,]", #"{"a" 1}"#, "{'a':1}", "[01]", "[1.]", "[\"tab\t\"]", "[1] x", "nul", ""] {
            #expect(JSONFormatter.minify(invalid) == nil, "\(invalid)")
        }
        #expect(JSONFormatter.isContainer(#" {"a":1} "#))
        #expect(!JSONFormatter.isContainer("\"text\""))
    }

    // MARK: Calculator

    @Test func calculator() throws {
        func calc(_ s: String) -> Double? { ArithmeticEvaluator.evaluateIfExpression(s) }
        #expect(calc("1 + 2 * 3") == 7)
        #expect(calc("(1 + 2) * 3") == 9)
        #expect(calc("2^3^2") == 512)
        #expect(calc("-2^2") == -4)
        #expect(calc("2^-1") == 0.5)
        #expect(calc("1,280 × 0.85 + 64") == 1152)
        #expect(calc("10 ÷ 4") == 2.5)
        #expect(calc("7 mod 3") == 1)
        #expect(calc("3 x 4") == 12)
        #expect(calc("2pi") == 2 * .pi)
        #expect(calc("3(4 + 1)") == 15)
        #expect(calc("200 + 15%") == 230)
        #expect(calc("80 - 25%") == 60)
        #expect(calc("15% of 80") == 12)
        #expect(calc("5!") == 120)
        #expect(calc("max(3, 9, 4) - min(2, 8)") == 7)
        #expect(calc("(3 + 4) / 2 =") == 3.5)
        #expect(calc("√16 + 1") == 5)
        #expect(calc("1e3 / 4") == 250)
        #expect(abs((calc("sqrt(2) * 100") ?? 0) - 141.42135623731) < 1e-9)
        #expect(abs((calc("sin(pi / 2) + log(1000)") ?? 0) - 4) < 1e-12)

        // Not calculations.
        for text in ["2026", "-5", "50%", "pi", "3.14", "2026-11-04", "11/04/2026", "10-20", "1.2.3", "555-123-4567",
                     "+1 (555) 123-4567", "10:30", "Chapter 3", "2 apples + 3", "1920x1080", "hello", "", "(", "2 +"] {
            #expect(calc(text) == nil, "\(text)")
        }
        #expect(calc("3/4") == 0.75)
        #expect(throws: ArithmeticEvaluator.Failure.divisionByZero) { try ArithmeticEvaluator.evaluate("1 / 0") }
        #expect(throws: ArithmeticEvaluator.Failure.domain) { try ArithmeticEvaluator.evaluate("sqrt(-1)") }
        #expect(throws: ArithmeticEvaluator.Failure.unknownName("foo")) { try ArithmeticEvaluator.evaluate("foo(2)") }

        #expect(ArithmeticEvaluator.canonical(1152) == "1152")
        #expect(ArithmeticEvaluator.canonical(0.1 + 0.2) == "0.3")
        #expect(ArithmeticEvaluator.canonical(1.0 / 3) == "0.333333333333")
        #expect(ArithmeticEvaluator.canonical(-2.5) == "-2.5")
        #expect(ArithmeticEvaluator.display(1152, locale: Locale(identifier: "en_US")) == "1,152")
        #expect(ArithmeticEvaluator.display(1152.5, locale: Locale(identifier: "de_DE")) == "1.152,5")
    }

    // MARK: Script IO

    @Test func shellActionContract() {
        let env = ScriptIO.environment(text: "héllo\nworld", appName: "Notes", bundleID: "com.apple.Notes", base: ["PATH": "/usr/bin"])
        #expect(env["MACTOYS_TEXT"] == "héllo\nworld")
        #expect(env["MACTOYS_APP_NAME"] == "Notes")
        #expect(env["MACTOYS_APP_BUNDLE_ID"] == "com.apple.Notes")
        #expect(env["PATH"] == "/usr/bin")
        #expect(env["LANG"] == "en_US.UTF-8")
        let huge = String(repeating: "x", count: 200_000)
        #expect((ScriptIO.environment(text: huge, appName: nil, bundleID: nil, base: [:])["MACTOYS_TEXT"]?.utf8.count ?? 0) <= 64 * 1024)
        #expect(ScriptIO.shellArguments("sort") == ["-l", "-c", "sort"])
        #expect(ScriptIO.shortcutArguments(name: "Summarize", input: URL(fileURLWithPath: "/tmp/in.txt"),
                                           output: URL(fileURLWithPath: "/tmp/out.txt"))
                == ["run", "Summarize", "--input-path", "/tmp/in.txt", "--output-path", "/tmp/out.txt", "--output-type", "public.plain-text"])

        #expect(ScriptIO.interpret(.init(status: 0, stdout: "HELLO\n", stderr: "")) == .success("HELLO"))
        #expect(ScriptIO.interpret(.init(status: 0, stdout: "a\n\n", stderr: "")) == .success("a\n"))
        #expect(ScriptIO.interpret(.init(status: 0, stdout: "crlf\r\n", stderr: "")) == .success("crlf"))
        #expect(ScriptIO.interpret(.init(status: 0, stdout: "", stderr: "warning only")) == .success(""))
        #expect(ScriptIO.interpret(.init(status: 2, stdout: "", stderr: "line 1\nzsh: command not found: jq\n"))
                == .failure("line 1\nzsh: command not found: jq"))
        #expect(ScriptIO.interpret(.init(status: 3, stdout: "partial", stderr: "  \n")) == .failure("The action failed with exit status 3."))
        if case .failure = ScriptIO.interpret(.init(status: 15, stdout: "", stderr: "", timedOut: true)) {} else {
            Issue.record("A timeout must fail")
        }

        #expect(ScriptIO.effect(of: "X", mode: .replace, editable: true) == .replace("X"))
        #expect(ScriptIO.effect(of: "X", mode: .replace, editable: false) == .copy("X"))
        #expect(ScriptIO.effect(of: "", mode: .replace, editable: true) == .nothing)
        #expect(ScriptIO.effect(of: "", mode: .copy, editable: true) == .nothing)
        #expect(ScriptIO.effect(of: "", mode: .show, editable: false) == .show(""))
        #expect(ScriptIO.effect(of: "X", mode: .ignore, editable: true) == .nothing)
    }

    @Test func appleScriptLiterals() {
        #expect(ScriptIO.appleScriptLiteral("plain") == #""plain""#)
        #expect(ScriptIO.appleScriptLiteral(#"say "hi" \ bye"#) == #""say \"hi\" \\ bye""#)
        #expect(ScriptIO.appleScriptLiteral("a\nb") == #"("a" & linefeed & "b")"#)
        #expect(ScriptIO.appleScriptLiteral("a\tb\r") == #"("a" & tab & "b" & return)"#)
        #expect(ScriptIO.appleScriptLiteral("") == #""""#)
        #expect(ScriptIO.appleScriptSource("display dialog {text}", text: "Hi \"you\"") == #"display dialog "Hi \"you\"""#)
    }

    // MARK: Custom actions file

    @Test func customActionsRoundTrip() throws {
        let actions = [
            CustomAction(name: "Search GitHub", symbol: "chevron.left.forwardslash.chevron.right", kind: .url,
                         template: "https://github.com/search?q={text}"),
            CustomAction(name: "Sort", kind: .shell, script: "sort", output: .replace, condition: .regex, pattern: "\\n"),
            CustomAction(name: "Bold", kind: .keyPress, keys: Shortcut(11, [.command])),
        ]
        let data = try CustomActionsFile.export(actions)
        let json = String(decoding: data, as: UTF8.self)
        #expect(json.contains("\"format\" : \"mactoys.textactions\""))
        #expect(!json.contains("\"script\" : \"\""))
        #expect(try CustomActionsFile.import(data) == actions)

        // Imports keep existing actions safe: colliding ids get new ones.
        let again = try CustomActionsFile.import(data, existing: Set(actions.map(\.id)))
        #expect(again.count == 3)
        #expect(Set(again.map(\.id)).isDisjoint(with: Set(actions.map(\.id))))
        #expect(again.map(\.name) == actions.map(\.name))
    }

    @Test func importIsTolerant() throws {
        let single = Data(#"{"type": "url", "url": "https://x.test/?q={text}"}"#.utf8)
        let one = try CustomActionsFile.import(single)
        #expect(one.count == 1)
        #expect(one[0].name == "URL")
        #expect(one[0].symbol == "link")
        #expect(one[0].condition == .any)

        let mixed = Data(#"[{"type": "shell", "name": "Up", "script": "tr a-z A-Z", "result": "replace"}, {"type": "teleport"}, 42]"#.utf8)
        let parsed = try CustomActionsFile.import(mixed)
        #expect(parsed.count == 1)
        #expect(parsed[0].output == .replace)
        #expect(throws: CustomActionsFile.ImportError.notActions) { try CustomActionsFile.import(Data("[]".utf8)) }
        #expect(throws: (any Error).self) { try CustomActionsFile.import(Data("nope".utf8)) }
    }

    @Test func settingsDecodeOverDefaults() throws {
        var s = TextActionsSettings()
        s.add(CustomAction(name: "Sort", kind: .shell, script: "sort"))
        s.labelStyle = .labels
        s.showShortcut = nil
        let decoded = try JSONDecoder().decode(TextActionsSettings.self, from: JSONEncoder().encode(s))
        #expect(decoded == s)
        #expect(TextActionsSettings().showShortcut == Shortcut(0, [.control, .option, .shift]))
    }

    // MARK: Placement

    private let screen = BarPlacement.Screen(frame: CGRect(x: 0, y: 0, width: 1512, height: 982),
                                             visible: CGRect(x: 0, y: 37, width: 1512, height: 870))
    private let bar = CGSize(width: 300, height: 40)

    @Test func barGoesAboveTheSelection() {
        let selection = CGRect(x: 600, y: 400, width: 120, height: 18)
        let frame = BarPlacement.frame(size: bar, anchor: selection, side: .above, screen: screen)
        #expect(frame == CGRect(x: 510, y: 352, width: 300, height: 40))
        let below = BarPlacement.frame(size: bar, anchor: selection, side: .below, screen: screen)
        #expect(below.minY == selection.maxY + BarPlacement.gap)
    }

    @Test func barFlipsAtTopAndBottomEdges() {
        // Just under the menu bar: no room above, so it goes below.
        let top = CGRect(x: 600, y: 50, width: 120, height: 18)
        let frame = BarPlacement.frame(size: bar, anchor: top, side: .above, screen: screen)
        #expect(frame.minY == top.maxY + BarPlacement.gap)
        // Near the Dock with "below" preferred: no room, so it goes above.
        let bottom = CGRect(x: 600, y: 880, width: 120, height: 18)
        let up = BarPlacement.frame(size: bar, anchor: bottom, side: .below, screen: screen)
        #expect(up.maxY == bottom.minY - BarPlacement.gap)
    }

    @Test func barStaysInsideHorizontally() {
        let left = BarPlacement.frame(size: bar, anchor: CGRect(x: 2, y: 400, width: 30, height: 18), side: .above, screen: screen)
        #expect(left.minX == BarPlacement.margin)
        let right = BarPlacement.frame(size: bar, anchor: CGRect(x: 1490, y: 400, width: 20, height: 18), side: .above, screen: screen)
        #expect(right.maxX == 1512 - BarPlacement.margin)
        // A second display to the left of the primary one (negative x).
        let external = BarPlacement.Screen(frame: CGRect(x: -1920, y: 0, width: 1920, height: 1080),
                                           visible: CGRect(x: -1920, y: 25, width: 1920, height: 1055))
        let f = BarPlacement.frame(size: bar, anchor: CGRect(x: -1915, y: 500, width: 10, height: 18), side: .above, screen: external)
        #expect(f.minX == -1920 + BarPlacement.margin)
    }

    @Test func barAvoidsTheNotch() {
        // Full-screen app: the visible frame reaches the top edge, the notch is in the middle.
        let notch = CGRect(x: 662, y: 0, width: 188, height: 37)
        let full = BarPlacement.Screen(frame: CGRect(x: 0, y: 0, width: 1512, height: 982),
                                       visible: CGRect(x: 0, y: 0, width: 1512, height: 982), notch: notch)
        let selection = CGRect(x: 700, y: 60, width: 100, height: 18)
        let frame = BarPlacement.frame(size: bar, anchor: selection, side: .above, screen: full)
        #expect(!frame.intersects(notch))
        #expect(frame.minY == selection.maxY + BarPlacement.gap)
        // Away from the notch horizontally, above is fine.
        let side = CGRect(x: 100, y: 60, width: 100, height: 18)
        #expect(BarPlacement.frame(size: bar, anchor: side, side: .above, screen: full).maxY == side.minY - BarPlacement.gap)
        // A selection filling the screen: overlap it, but below the notch.
        let huge = CGRect(x: 600, y: 10, width: 300, height: 960)
        let overlap = BarPlacement.frame(size: bar, anchor: huge, side: .above, screen: full)
        #expect(overlap.minY >= notch.maxY)
        #expect(overlap.maxY <= 982)
    }

    @Test func anchorsForTallSelections() {
        let tall = CGRect(x: 100, y: 200, width: 500, height: 180)
        let down = BarPlacement.anchor(selection: tall, pointer: CGPoint(x: 320, y: 370), dragStart: CGPoint(x: 110, y: 205),
                                       preferred: .above)
        #expect(down.side == .below)
        #expect(down.rect.midX == 320)
        let up = BarPlacement.anchor(selection: tall, pointer: CGPoint(x: 120, y: 210), dragStart: CGPoint(x: 580, y: 370),
                                     preferred: .below)
        #expect(up.side == .above)
        let keyboard = BarPlacement.anchor(selection: tall, pointer: nil, dragStart: nil, preferred: .below)
        #expect(keyboard.side == .above)
        #expect(keyboard.rect.minY == 200 && keyboard.rect.height == 20)
        let line = CGRect(x: 100, y: 200, width: 80, height: 18)
        #expect(BarPlacement.anchor(selection: line, pointer: CGPoint(x: 900, y: 900), dragStart: nil, preferred: .below)
                == (line, .below))
        let none = BarPlacement.anchor(selection: nil, pointer: CGPoint(x: 50, y: 60), dragStart: nil, preferred: .above)
        #expect(none.rect.midX == 50 && none.rect.midY == 60)
    }

    // MARK: Gestures

    @Test func gestures() {
        let t = TextActionsSettings.Triggers()
        let p = CGPoint(x: 100, y: 100)
        #expect(SelectionGesture.classify(down: p, up: CGPoint(x: 160, y: 102), clickCount: 1, flags: [], triggers: t, required: .none) == .drag)
        #expect(SelectionGesture.classify(down: p, up: p, clickCount: 2, flags: [], triggers: t, required: .none) == .multiClick)
        #expect(SelectionGesture.classify(down: p, up: p, clickCount: 3, flags: [], triggers: t, required: .none) == .multiClick)
        #expect(SelectionGesture.classify(down: p, up: p, clickCount: 1, flags: .shift, triggers: t, required: .none) == .shiftClick)
        #expect(SelectionGesture.classify(down: p, up: CGPoint(x: 102, y: 101), clickCount: 1, flags: [], triggers: t, required: .none) == nil)
        // ⌘ skips once; a required modifier must be held.
        #expect(SelectionGesture.classify(down: p, up: CGPoint(x: 160, y: 100), clickCount: 1, flags: .command, triggers: t, required: .none) == nil)
        #expect(SelectionGesture.classify(down: p, up: CGPoint(x: 160, y: 100), clickCount: 1, flags: [], triggers: t, required: .option) == nil)
        #expect(SelectionGesture.classify(down: p, up: CGPoint(x: 160, y: 100), clickCount: 1, flags: .option, triggers: t, required: .option) == .drag)
        #expect(SelectionGesture.classify(down: p, up: CGPoint(x: 160, y: 100), clickCount: 1, flags: .command, triggers: t, required: .command) == .drag)
        var noDrag = t
        noDrag.drag = false
        #expect(SelectionGesture.classify(down: p, up: CGPoint(x: 160, y: 100), clickCount: 1, flags: [], triggers: noDrag, required: .none) == nil)
        #expect(SelectionGesture.Kind.shortcut.isAutomatic == false)
        #expect(SelectionGesture.Kind.drag.isAutomatic)
    }
}
