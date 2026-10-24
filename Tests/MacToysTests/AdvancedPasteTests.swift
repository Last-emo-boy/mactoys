import AppKit
import Foundation
import Testing
@testable import AdvancedPaste
@testable import MacToysCore

@Suite struct AdvancedPasteTests {
    // MARK: HTML → Markdown

    @Test func powerToysSample() {
        let html = #"<b>Paste</b> <i>as</i> <a href="https://en.wikipedia.org/wiki/Markdown">Markdown</a>"#
        #expect(HTMLToMarkdown.convert(html) == "**Paste** *as* [Markdown](https://en.wikipedia.org/wiki/Markdown)")
    }

    @Test func headingsAndParagraphs() {
        let html = "<h1>Title</h1><p>First   paragraph\n with  <em>emphasis</em>.</p><h3>Sub</h3><p>Second</p>"
        #expect(HTMLToMarkdown.convert(html) == "# Title\n\nFirst paragraph with *emphasis*.\n\n### Sub\n\nSecond")
    }

    @Test func nestedLists() {
        let html = """
        <ul><li>One</li><li>Two<ul><li>Two A</li><li>Two B</li></ul></li><li>Three</li></ul>
        <ol start="3"><li>Third</li><li>Fourth</li></ol>
        """
        #expect(HTMLToMarkdown.convert(html) == "- One\n- Two\n  - Two A\n  - Two B\n- Three\n\n3. Third\n4. Fourth")
    }

    @Test func unclosedListItemsAndTaskLists() {
        let html = "<ul><li><input type=checkbox checked> Done<li><input type=checkbox> Todo</ul>"
        #expect(HTMLToMarkdown.convert(html) == "- [x] Done\n- [ ] Todo")
    }

    @Test func linksImagesAndTitles() {
        let html = #"<p>See <a href="https://example.com/a b" title="Ex">the docs</a> and <a href="https://x.dev">https://x.dev</a>. <img src="/i.png" alt="Logo [v2]"></p>"#
        #expect(HTMLToMarkdown.convert(html)
            == #"See [the docs](https://example.com/a%20b "Ex") and <https://x.dev>. ![Logo \[v2\]](/i.png)"#)
    }

    @Test func inlineCodeAndCodeBlocks() {
        let html = #"<p>Use <code>a `b` c</code> here</p><pre><code class="language-swift">let x = 1&lt;2"#
            + "\nprint(x)\n</code></pre>"
        #expect(HTMLToMarkdown.convert(html) == "Use ``a `b` c`` here\n\n```swift\nlet x = 1<2\nprint(x)\n```")
    }

    @Test func tablesWithAlignmentAndPipes() {
        let html = """
        <table><thead><tr><th>Name</th><th align="right">Qty</th><th style="text-align:center">Note</th></tr></thead>
        <tbody><tr><td>Apples</td><td>12</td><td>a|b</td></tr><tr><td><b>Pears</b></td><td>3</td><td></td></tr></tbody></table>
        """
        let expected = """
        | Name      | Qty | Note |
        | --------- | --: | :--: |
        | Apples    |  12 | a\\|b |
        | **Pears** |   3 |      |
        """
        #expect(HTMLToMarkdown.convert(html) == expected)
    }

    @Test func tableWithoutHeaderUsesFirstRowAndColspan() {
        let html = "<table><tr><td>a</td><td>b</td></tr><tr><td colspan=2>wide</td></tr></table>"
        #expect(HTMLToMarkdown.convert(html) == "| a    | b   |\n| ---- | --- |\n| wide |     |")
    }

    @Test func blockquoteAndRule() {
        let html = "<blockquote><p>Quote one</p><p>Quote two</p></blockquote><hr><p>After</p>"
        #expect(HTMLToMarkdown.convert(html) == "> Quote one\n>\n> Quote two\n\n---\n\nAfter")
    }

    @Test func googleDocsStylesAndEntities() {
        let html = #"<meta charset="utf-8"><b style="font-weight:normal;" id="docs-internal-guid-1"><p><span style="font-weight:700">Bold</span> and <span style="font-style:italic">italic</span> &amp; <span style="text-decoration:line-through">gone</span>&nbsp;&mdash; caf&eacute;</p></b>"#
        #expect(HTMLToMarkdown.convert(html) == "**Bold** and *italic* & ~~gone~~ — café")
    }

    @Test func escapesMarkdownInText() {
        let html = "<p>2 * 3 = 6 and snake_case [x]</p><p># not a heading</p><p>1. not a list</p>"
        #expect(HTMLToMarkdown.convert(html) == "2 \\* 3 = 6 and snake\\_case \\[x\\]\n\n\\# not a heading\n\n1\\. not a list")
    }

    @Test func skipsScriptsStylesAndComments() {
        let html = "<style>p{color:red}</style><!--StartFragment--><p>Hi<script>alert(1)</script></p><!--EndFragment-->"
        #expect(HTMLToMarkdown.convert(html) == "Hi")
    }

    @Test func lineBreaks() {
        #expect(HTMLToMarkdown.convert("<p>one<br>two<br/>three</p>") == "one  \ntwo  \nthree")
    }

    @Test func plainTextFromHTML() {
        let html = "<h2>List</h2><ul><li>a</li><li><b>b</b></li></ul><table><tr><td>1</td><td>2</td></tr><tr><td>3</td><td>4</td></tr></table>"
        #expect(HTMLToMarkdown.plainText(html) == "List\n\n• a\n• b\n\n1\t2\n3\t4")
    }

    // MARK: JSON

    @Test func csvWithHeaderBecomesObjects() {
        let csv = "name,age,active,zip\nAda,36,true,00123\n\"Lovelace, A\",,false,\"9\"\"9\""
        let expected = """
        [
          {
            "name": "Ada",
            "age": 36,
            "active": true,
            "zip": "00123"
          },
          {
            "name": "Lovelace, A",
            "age": "",
            "active": false,
            "zip": "9\\"9"
          }
        ]
        """
        #expect(JSONConverter.convert(csv) == expected)
        #expect(JSONConverter.detect(csv) == .delimited(",", rows: 2))
    }

    @Test func tsvAndHeaderlessRows() {
        #expect(JSONConverter.detect("a\tb\nc\td") == .delimited("\t", rows: 1))
        #expect(JSONConverter.value(for: "1,2\n3,4") == .array([.array([.number("1"), .number("2")]),
                                                               .array([.number("3"), .number("4")])]))
    }

    @Test func xmlToJSON() {
        let xml = """
        <?xml version="1.0"?>
        <note id="7">
            <to>Mr. Smith</to>
            <from>Ms. Nguyen</from>
            <tag>a</tag><tag>b</tag>
            <empty/>
            <body lang="en">Do you like PowerToys?</body>
        </note>
        """
        let expected = """
        {
          "note": {
            "@id": "7",
            "to": "Mr. Smith",
            "from": "Ms. Nguyen",
            "tag": [
              "a",
              "b"
            ],
            "empty": null,
            "body": {
              "@lang": "en",
              "#text": "Do you like PowerToys?"
            }
          }
        }
        """
        #expect(JSONConverter.convert(xml) == expected)
    }

    @Test func yamlToJSON() {
        let yaml = """
        # service
        name: api
        port: 8080
        debug: false
        tags: [web, "v2"]
        owner: ~
        env:
          - name: HOST
            value: 0.0.0.0
          - name: MODE
            value: 'prod' # comment
        script: |
          make
          make test
        """
        let value = JSONConverter.value(for: yaml)
        #expect(JSONConverter.detect(yaml) == .yaml)
        #expect(value == .object([
            .init("name", .string("api")),
            .init("port", .number("8080")),
            .init("debug", .bool(false)),
            .init("tags", .array([.string("web"), .string("v2")])),
            .init("owner", .null),
            .init("env", .array([
                .object([.init("name", .string("HOST")), .init("value", .string("0.0.0.0"))]),
                .object([.init("name", .string("MODE")), .init("value", .string("prod"))]),
            ])),
            .init("script", .string("make\nmake test\n")),
        ]))
    }

    @Test func yamlSequenceAtKeyIndent() {
        let yaml = "fruits:\n- apple\n- pear\ncount: 2"
        #expect(JSONConverter.value(for: yaml) == .object([
            .init("fruits", .array([.string("apple"), .string("pear")])), .init("count", .number("2")),
        ]))
    }

    @Test func iniAndKeyValue() {
        let ini = "; settings\nglobal = yes\n[server]\nhost=localhost\nport = \"80\"\n[client]\nexport TOKEN=abc"
        #expect(JSONConverter.value(for: ini) == .object([
            .init("global", .string("yes")),
            .init("server", .object([.init("host", .string("localhost")), .init("port", .string("80"))])),
            .init("client", .object([.init("TOKEN", .string("abc"))])),
        ]))
        #expect(JSONConverter.detect(ini) == .keyValue(keys: 4))
    }

    @Test func existingJSONIsPrettyPrintedInOrder() {
        let json = #"{"b":1,"a":[true,null,"x\n"],"c":{"z":1.50,"e":"é😀"}}"#
        let expected = """
        {
          "b": 1,
          "a": [
            true,
            null,
            "x\\n"
          ],
          "c": {
            "z": 1.50,
            "e": "é😀"
          }
        }
        """
        #expect(JSONConverter.convert(json) == expected)
    }

    @Test func otherTextBecomesLines() {
        #expect(JSONConverter.convert("hello world\n\n second line ") == "[\n  \"hello world\",\n  \"second line\"\n]")
        #expect(JSONParser.parse("{\"a\":01}") == nil)
        #expect(JSONParser.isCanonicalNumber("-0.5e3"))
        #expect(!JSONParser.isCanonicalNumber("007"))
    }

    // MARK: Actions

    @Test func actionParsing() {
        typealias A = AdvancedPasteTransforms.Action
        #expect(A(name: "plain-text") == .plainText)
        #expect(A(name: "Plain Text") == .plainText)
        #expect(A(name: "MD") == .markdown)
        #expect(A(name: "paste_as_txt_file") == .txtFile)
        #expect(A(name: "html") == .htmlFile)
        #expect(A(name: "ocr") == .imageToText)
        #expect(A(name: "transcode-to-mp4") == .transcodeMP4)
        #expect(A(name: "aac") == .transcodeM4A)
        #expect(A(name: "paste-with-ai") == nil)
        #expect(A(name: "nope") == nil)
        for action in A.builtIns { #expect(A(name: action.name) == action) }
    }

    @Test func actionsAcceptMatchingInput() {
        typealias A = AdvancedPasteTransforms.Action
        let text = AdvancedPasteTransforms.Input(text: "hi")
        let video = AdvancedPasteTransforms.Input(files: [URL(fileURLWithPath: "/tmp/clip.mov")])
        let audio = AdvancedPasteTransforms.Input(files: [URL(fileURLWithPath: "/tmp/song.wav")])
        let image = AdvancedPasteTransforms.Input(image: Data([0x89, 0x50, 0x4E, 0x47]))
        #expect(A.plainText.accepts(text) && A.json.accepts(text) && !A.htmlFile.accepts(text))
        #expect(A.htmlFile.accepts(.init(text: "x", html: "<b>x</b>")))
        #expect(A.transcodeMP4.accepts(video) && A.transcodeMP3.accepts(video))
        #expect(A.transcodeM4A.accepts(audio) && !A.transcodeMP4.accepts(audio))
        #expect(A.imageToText.accepts(image) && A.pngFile.accepts(image) && !A.markdown.accepts(image))
    }

    @Test func transformsProduceTextAndFiles() async throws {
        let md = try await AdvancedPasteTransforms.apply(.markdown, to: .init(text: "x", html: "<h2>Hi</h2>"))
        #expect(md == .text("## Hi"))
        let plain = try await AdvancedPasteTransforms.apply(.plainText, to: .init(html: "<p>a</p><p>b</p>"))
        #expect(plain == .text("a\n\nb"))
        let file = try await AdvancedPasteTransforms.apply(.txtFile, to: .init(text: "Hello World!"))
        guard case .file(let url) = file else { Issue.record("expected a file"); return }
        #expect(url.pathExtension == "txt")
        #expect(try String(contentsOf: url, encoding: .utf8) == "Hello World!")
        await #expect(throws: AdvancedPasteTransforms.TransformError.self) {
            try await AdvancedPasteTransforms.apply(.pngFile, to: .init(text: "no image"))
        }
    }

    @Test func clipboardSummaryLabels() {
        #expect(ClipboardSummary.textDetail("name,role\nAda,Engineer\nLin,Ops") == "CSV · 2 rows")
        #expect(ClipboardSummary.textDetail("https://github.com/x") == "Link")
        #expect(ClipboardSummary.textDetail("three little words") == "Text · 3 words")
        #expect(ClipboardSummary.snippet("a\nb") == "a ↵ b")
    }

    // MARK: AI

    @Test func aiRequestShapes() throws {
        let openAI = try AIClient.request(provider: .preset(.openAI), apiKey: "sk-1", instructions: "Shout", content: "hi")
        #expect(openAI.url?.absoluteString == "https://api.openai.com/v1/chat/completions")
        #expect(openAI.value(forHTTPHeaderField: "Authorization") == "Bearer sk-1")
        let body = try #require(openAI.httpBody.flatMap { try JSONSerialization.jsonObject(with: $0) as? [String: Any] })
        #expect(body["model"] as? String == "gpt-4o-mini")

        var azure = AIProvider.preset(.azureOpenAI)
        azure.endpoint = "https://res.openai.azure.com/"
        azure.model = "my deploy"
        let az = try AIClient.request(provider: azure, apiKey: "k", instructions: "x", content: "y")
        #expect(az.url?.absoluteString == "https://res.openai.azure.com/openai/deployments/my%20deploy/chat/completions?api-version=2024-10-21")
        #expect(az.value(forHTTPHeaderField: "api-key") == "k")

        let local = try AIClient.request(provider: .preset(.ollama), apiKey: nil, instructions: "x", content: "y")
        #expect(local.url?.absoluteString == "http://localhost:11434/v1/chat/completions")
        #expect(local.value(forHTTPHeaderField: "Authorization") == nil)

        #expect(throws: AIError.missingKey) {
            try AIClient.request(provider: .preset(.openAI), apiKey: "", instructions: "x", content: "y")
        }
    }

    @Test func aiResponseParsing() throws {
        let ok = Data(#"{"choices":[{"message":{"role":"assistant","content":"  Bonjour  "}}]}"#.utf8)
        #expect(try AIClient.parse(ok, status: 200) == "Bonjour")
        let err = Data(#"{"error":{"message":"You exceeded your current quota"}}"#.utf8)
        #expect(throws: AIError.server(status: 429, message: "You exceeded your current quota")) {
            try AIClient.parse(err, status: 429)
        }
    }

    @Test func settingsRoundTripKeepsNewActionDefaults() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let store = SettingsStore(directory: dir)
        var s = AdvancedPasteSettings()
        s.actions["json"] = ActionPrefs(enabled: false, shortcut: nil)
        s.actions.removeValue(forKey: "transcode-to-m4a")
        store.save(s, id: "ap")
        let loaded = store.load("ap", default: AdvancedPasteSettings())
        #expect(loaded.prefs(.json).enabled == false)
        #expect(loaded.actions["transcode-to-m4a"] != nil)
        #expect(loaded.prefs(.plainText).shortcut == AdvancedPasteSettings().prefs(.plainText).shortcut)
    }

    // MARK: Pasteboard and window

    @Test func inputReadsEveryFlavorAndSnapshotRoundTrips() async throws {
        let pb = NSPasteboard(name: NSPasteboard.Name("mactoys.tests.\(UUID().uuidString)"))
        defer { pb.releaseGlobally() }
        pb.clearContents()
        let item = NSPasteboardItem()
        item.setString("a\tb", forType: .string)
        item.setString("<table><tr><td>a</td><td>b</td></tr></table>", forType: .html)
        item.setData(Data([0x89, 0x50, 0x4E, 0x47]), forType: .png)
        item.setData(Data("private".utf8), forType: NSPasteboard.PasteboardType("com.example.private"))
        pb.writeObjects([item])

        let input = AdvancedPasteTransforms.Input(pasteboard: pb)
        #expect(input.text == "a\tb")
        #expect(input.html?.contains("<td>a</td>") == true)
        #expect(input.image == Data([0x89, 0x50, 0x4E, 0x47]))
        #expect(AdvancedPasteTransforms.Action.markdown.accepts(input) && AdvancedPasteTransforms.Action.pngFile.accepts(input))
        #expect(ClipboardSummary(input).detail == "Rich text · HTML")

        let snapshot = try #require(PasteboardSnapshot.capture(pb))
        pb.clearContents()
        pb.setString("replaced", forType: .string)
        await MainActor.run { snapshot.restore(pb) }
        #expect(pb.string(forType: .string) == "a\tb")
        #expect(pb.data(forType: NSPasteboard.PasteboardType("com.example.private")) == Data("private".utf8))
    }

    @MainActor @Test func sessionNumbersActionsAndSkipsTheCurrentHistoryEntry() {
        var settings = AdvancedPasteSettings()
        settings.aiEnabled = true
        settings.customActions = [CustomAction(name: "Shout", prompt: "Uppercase it"), CustomAction(name: "Off", prompt: "x", isEnabled: false)]
        let history = [ClipItem(kind: .text, text: "hello"), ClipItem(kind: .text, text: "older")]
        let session = PasteSession(input: .init(text: "hello"), settings: settings, history: history)
        let titles = session.rows.map(\.title)
        #expect(titles == ["Plain text", "Markdown", "JSON", ".txt file", "Shout", "older"])
        #expect(session.row(number: 5)?.title == "Shout")
        #expect(session.rows.last?.number == nil)
        session.moveSelection(-1)
        #expect(session.selectedRow?.title == "older")

        settings.aiEnabled = false
        settings.historyEnabled = false
        settings.actions["markdown"]?.enabled = false
        let plain = PasteSession(input: .init(text: "hello"), settings: settings, history: history)
        #expect(plain.rows.map(\.title) == ["Plain text", "JSON", ".txt file"])
        #expect(!plain.showsPrompt)
        #expect(PasteSession(input: .init(), settings: settings, history: []).isEmpty)
    }
}
