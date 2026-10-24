import Foundation
import Testing
@testable import PreviewKit

@Suite struct PreviewKitMarkdownTests {
    private func md(_ s: String, html: Bool = true) -> String {
        MarkdownRenderer.body(s, options: MarkdownOptions(allowHTML: html, highlightCode: false))
    }

    @Test func headings() {
        #expect(md("# Title") == "<h1 id=\"title\">Title</h1>\n")
        #expect(md("### Deep ###") == "<h3 id=\"deep\">Deep</h3>\n")
        #expect(md("Setext\n===") == "<h1 id=\"setext\">Setext</h1>\n")
        #expect(md("Two\n---") == "<h2 id=\"two\">Two</h2>\n")
        #expect(md("#NoSpace") == "<p>#NoSpace</p>\n")
        #expect(md("# A\n# A") == "<h1 id=\"a\">A</h1>\n<h1 id=\"a-1\">A</h1>\n")
    }

    @Test func emphasis() {
        #expect(md("*a* **b** ***c***") == "<p><em>a</em> <strong>b</strong> <em><strong>c</strong></em></p>\n")
        #expect(md("_a_ __b__") == "<p><em>a</em> <strong>b</strong></p>\n")
        #expect(md("snake_case_name") == "<p>snake_case_name</p>\n")
        #expect(md("~~gone~~") == "<p><del>gone</del></p>\n")
        #expect(md("2 * 3 * 4") == "<p>2 * 3 * 4</p>\n")
        #expect(md("**unclosed") == "<p>**unclosed</p>\n")
        #expect(md("*nested **strong** here*") == "<p><em>nested <strong>strong</strong> here</em></p>\n")
    }

    @Test func codeSpansAndEscapes() {
        #expect(md("`a < b`") == "<p><code>a &lt; b</code></p>\n")
        #expect(md("`` a ` b ``") == "<p><code>a ` b</code></p>\n")
        #expect(md("\\*not em\\*") == "<p>*not em*</p>\n")
        #expect(md("a &amp; b & c") == "<p>a &amp; b &amp; c</p>\n")
        #expect(md("line one  \nline two") == "<p>line one<br>\nline two</p>\n")
    }

    @Test func links() {
        #expect(md("[x](https://a.com \"T\")") == "<p><a href=\"https://a.com\" title=\"T\">x</a></p>\n")
        #expect(md("[x][r]\n\n[r]: /url") == "<p><a href=\"/url\">x</a></p>\n")
        #expect(md("[R]\n\n[r]: /u 'title'") == "<p><a href=\"/u\" title=\"title\">R</a></p>\n")
        #expect(md("<https://example.com/a>") == "<p><a href=\"https://example.com/a\">https://example.com/a</a></p>\n")
        #expect(md("see www.example.com.") == "<p>see <a href=\"http://www.example.com\">www.example.com</a>.</p>\n")
        #expect(md("mail a@b.co now") == "<p>mail <a href=\"mailto:a@b.co\">a@b.co</a> now</p>\n")
        #expect(md("[bad](javascript:alert(1))") == "<p><a href=\"#\">bad</a></p>\n")
        #expect(md("[no link]") == "<p>[no link]</p>\n")
    }

    @Test func images() {
        let html = MarkdownRenderer.body("![alt *x*](pic.png)", options: MarkdownOptions()) { "data:" + $0 }
        #expect(html == "<p><img src=\"data:pic.png\" alt=\"alt x\"></p>\n")
        let blocked = MarkdownRenderer.body("![logo](https://x/y.png)", options: MarkdownOptions()) { _ in nil }
        #expect(blocked.contains("img-blocked"))
        #expect(MarkdownRenderer.imageSources(in: "![a](1.png) ![b](2.png) ![c](1.png)") == ["1.png", "2.png"])
    }

    @Test func lists() {
        #expect(md("- a\n- b") == "<ul>\n<li>a</li>\n<li>b</li>\n</ul>\n")
        #expect(md("3. a\n4. b") == "<ol start=\"3\">\n<li>a</li>\n<li>b</li>\n</ol>\n")
        #expect(md("- a\n\n- b") == "<ul>\n<li><p>a</p>\n</li>\n<li><p>b</p>\n</li>\n</ul>\n")
        #expect(md("- a\n  - b\n- c") == "<ul>\n<li>a\n<ul>\n<li>b</li>\n</ul>\n</li>\n<li>c</li>\n</ul>\n")
        #expect(md("- [ ] todo\n- [x] done") ==
            "<ul>\n<li class=\"task\"><input type=\"checkbox\" disabled> todo</li>\n<li class=\"task\"><input type=\"checkbox\" disabled checked> done</li>\n</ul>\n")
        #expect(md("- a\nlazy") == "<ul>\n<li>a\nlazy</li>\n</ul>\n")
    }

    @Test func codeBlocks() {
        #expect(md("```swift\nlet a = 1\n```") == "<pre><code class=\"language-swift\">let a = 1\n</code></pre>\n")
        #expect(md("    indented\n    code") == "<pre><code>indented\ncode\n</code></pre>\n")
        #expect(md("~~~\n<b>\n~~~") == "<pre><code>&lt;b&gt;\n</code></pre>\n")
        let highlighted = MarkdownRenderer.body("```js\nreturn 1\n```")
        #expect(highlighted.contains("<span class=\"kw\">return</span>"))
        #expect(highlighted.contains("<span class=\"num\">1</span>"))
    }

    @Test func tables() {
        let html = md("| a | b |\n|:--|--:|\n| 1 | `x\\|y` |")
        #expect(html.contains("<th style=\"text-align:left\">a</th><th style=\"text-align:right\">b</th>"))
        #expect(html.contains("<td style=\"text-align:left\">1</td><td style=\"text-align:right\"><code>x|y</code></td>"))
    }

    @Test func quotesRulesAndHTML() {
        #expect(md("> quoted\ncontinued") == "<blockquote>\n<p>quoted\ncontinued</p>\n</blockquote>\n")
        #expect(md("a\n\n***\n\nb") == "<p>a</p>\n<hr>\n<p>b</p>\n")
        #expect(md("<div>\n*raw*\n</div>") == "<div>\n*raw*\n</div>\n")
        #expect(md("<div>x</div>", html: false) == "<p>&lt;div&gt;x&lt;/div&gt;</p>\n")
        #expect(md("a <kbd>K</kbd> b") == "<p>a <kbd>K</kbd> b</p>\n")
        #expect(md("a <kbd>K</kbd>", html: false) == "<p>a &lt;kbd&gt;K&lt;/kbd&gt;</p>\n")
    }

    @Test func footnotes() {
        let html = md("Text[^1].\n\n[^1]: The note.")
        #expect(html.contains("<sup class=\"fnref\"><a href=\"#fn-1\" id=\"fnref-1\">1</a></sup>"))
        #expect(html.contains("<li id=\"fn-1\">"))
        #expect(html.contains("The note."))
    }

    @Test func pageBlocksScriptsAndRemoteImagesByDefault() {
        let page = MarkdownRenderer.page("# Hi", title: "t")
        #expect(page.contains("default-src 'none'"))
        #expect(page.contains("img-src data: cid:;"))
        #expect(!page.contains("https:"))
        let remote = MarkdownRenderer.page("# Hi", title: "t", allowRemoteImages: true)
        #expect(remote.contains("img-src data: cid: https: http:"))
    }

    @Test func localImagesStayInsideTheDocumentFolder() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir.appendingPathComponent("img"), withIntermediateDirectories: true)
        let doc = dir.appendingPathComponent("README.md")
        try Data([0x89, 0x50, 0x4E, 0x47]).write(to: dir.appendingPathComponent("img/a.png"))
        let policy = MarkdownImagePolicy(documentURL: doc)
        #expect(policy.resolve("img/a.png") == "data:image/png;base64,iVBORw==")
        #expect(policy.resolve("../outside.png") == nil)
        #expect(policy.resolve("https://x.org/a.png") == nil)
        let remote = MarkdownImagePolicy(documentURL: doc, allowRemoteImages: true)
        #expect(remote.resolve("https://x.org/a.png") == "https://x.org/a.png")
        let noLocal = MarkdownImagePolicy(documentURL: doc, showLocalImages: false)
        #expect(noLocal.resolve("img/a.png") == nil)
    }
}
