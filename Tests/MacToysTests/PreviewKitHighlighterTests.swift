import Foundation
import Testing
@testable import PreviewKit

@Suite struct PreviewKitHighlighterTests {
    private func kinds(_ code: String, _ lang: Language) -> [Token] {
        SyntaxHighlighter.tokenize(code, language: lang).filter { $0.kind != .plain }
    }

    @Test func tokensConcatenateToTheInputForEveryLanguage() {
        let sample = """
        #!/usr/bin/env thing
        // comment /* block */ "string \\" escaped" 'c' 0x1F 3.14e-2 `tpl ${x}`
        <tag attr="v">&amp; text</tag> key: value [section] a = 1
        @@ -1 +1 @@ + added - removed $VAR ${HOME} # hash
        let ü = "ünïcødé" 🚀 r#"raw"# '''py''' --[[ lua ]] =begin
        """
        for lang in Language.all {
            let joined = SyntaxHighlighter.tokenize(sample, language: lang).map(\.text).joined()
            #expect(joined == sample, "\(lang.id) lost text")
        }
    }

    @Test func swiftKeywordsStringsCommentsTypes() {
        let t = kinds("let x: Int = \"hi\" // note\n@MainActor struct Foo {}", .swift)
        #expect(t == [Token(.keyword, "let"), Token(.type, "Int"), Token(.string, "\"hi\""), Token(.comment, "// note"),
                      Token(.attribute, "@MainActor"), Token(.keyword, "struct"), Token(.type, "Foo")])
    }

    @Test func nestedBlockCommentsAndMultilineStrings() {
        let t = kinds("/* a /* b */ c */ x\n\"\"\"\nline\n\"\"\"", .swift)
        #expect(t == [Token(.comment, "/* a /* b */ c */"), Token(.string, "\"\"\"\nline\n\"\"\"")])
    }

    @Test func pythonDecoratorsTripleQuotesAndDefinitions() {
        let t = kinds("@cache\ndef go(n):\n    '''doc'''\n    return f\"{n}\" or None", .python)
        #expect(t == [Token(.attribute, "@cache"), Token(.keyword, "def"), Token(.function, "go"), Token(.string, "'''doc'''"),
                      Token(.keyword, "return"), Token(.string, "f\"{n}\""), Token(.keyword, "or"), Token(.literal, "None")])
    }

    @Test func numbers() {
        let t = kinds("a = 0xFF + 1_000 + 2.5e3 + 7u + .5", .c)
        #expect(t.map(\.text) == ["0xFF", "1_000", "2.5e3", "7u", ".5"])
        #expect(t.allSatisfy { $0.kind == .number })
        #expect(kinds("x1 = 2", .c) == [Token(.number, "2")])     // no number inside identifiers
    }

    @Test func cPreprocessorAndCharLiterals() {
        let t = kinds("#include <stdio.h>\nchar c = 'x';", .c)
        #expect(t == [Token(.meta, "#include <stdio.h>"), Token(.type, "char"), Token(.string, "'x'")])
    }

    @Test func rustLifetimesAreNotStrings() {
        let t = kinds("fn f<'a>(s: &'a str) -> char { 'z' }", .rust)
        #expect(t.contains(Token(.string, "'z'")))
        #expect(!t.contains { $0.kind == .string && $0.text.hasPrefix("'a") })
        #expect(t.contains(Token(.type, "str")))
    }

    @Test func javascriptRegexVersusDivision() {
        #expect(kinds("const r = /ab+c/gi;", .javascript).contains(Token(.regex, "/ab+c/gi")))
        #expect(!kinds("x = a / b / c", .javascript).contains { $0.kind == .regex })
        #expect(kinds("s = `a\nb`", .javascript).contains(Token(.string, "`a\nb`")))
    }

    @Test func shellVariablesAndComments() {
        let t = kinds("echo $HOME ${USER:-me} # note\nurl=a#b", .shell)
        #expect(t == [Token(.builtin, "echo"), Token(.variable, "$HOME"), Token(.variable, "${USER:-me}"), Token(.comment, "# note")])
    }

    @Test func sqlIsCaseInsensitive() {
        let t = kinds("SELECT name FROM users WHERE id = 1 -- c", .sql)
        #expect(t == [Token(.keyword, "SELECT"), Token(.keyword, "FROM"), Token(.keyword, "WHERE"), Token(.number, "1"), Token(.comment, "-- c")])
    }

    @Test func jsonKeysAreProperties() {
        let t = kinds("{\"a\": \"b\", \"n\": -1.5, \"t\": true}", .json)
        #expect(t == [Token(.property, "\"a\""), Token(.string, "\"b\""), Token(.property, "\"n\""), Token(.number, "-1.5"),
                      Token(.property, "\"t\""), Token(.literal, "true")])
    }

    @Test func markupTagsAttributesAndEmbeddedScript() {
        let t = kinds("<!-- c --><a href=\"x\">&amp;</a>", .xml)
        #expect(t == [Token(.comment, "<!-- c -->"), Token(.tag, "<"), Token(.tag, "a"), Token(.attrName, "href"),
                      Token(.attrValue, "\"x\""), Token(.tag, ">"), Token(.escape, "&amp;"), Token(.tag, "</"), Token(.tag, "a"), Token(.tag, ">")])
        let html = kinds("<script>let a = 1</script>", .html)
        #expect(html.contains(Token(.keyword, "let")))
        #expect(html.contains(Token(.number, "1")))
    }

    @Test func cssSelectorsPropertiesValues() {
        let t = kinds(".btn:hover { color: #fff; margin: 4px !important; }", .css)
        #expect(t == [Token(.attrName, ".btn"), Token(.keyword, ":hover"), Token(.property, "color"), Token(.number, "#fff"),
                      Token(.property, "margin"), Token(.number, "4px"), Token(.keyword, "!important")])
    }

    @Test func yamlKeysValuesComments() {
        let t = kinds("name: demo # c\nlist:\n  - 3\n  - yes\ntext: |\n  block\n", .yaml)
        #expect(t.contains(Token(.property, "name")))
        #expect(t.contains(Token(.string, "demo")))
        #expect(t.contains(Token(.comment, "# c")))
        #expect(t.contains(Token(.number, "3")))
        #expect(t.contains(Token(.literal, "yes")))
        #expect(t.contains(Token(.string, "  block")))
    }

    @Test func iniTomlSectionsAndKeys() {
        let t = kinds("[server]\nport = 8080 # c\nname = \"x\"", .toml)
        #expect(t == [Token(.section, "[server]"), Token(.property, "port"), Token(.number, "8080"), Token(.comment, "# c"),
                      Token(.property, "name"), Token(.string, "\"x\"")])
    }

    @Test func diffLines() {
        let t = kinds("--- a\n+++ b\n@@ -1 +1 @@\n-old\n+new\n same", .diff)
        #expect(t.map(\.kind) == [.meta, .meta, .section, .deleted, .inserted])
    }

    @Test func makefileTargetsAndVariables() {
        let t = kinds("CC := clang\nall: main.o\n\t$(CC) -o $@ $^", .makefile)
        #expect(t.contains(Token(.property, "CC")))
        #expect(t.contains(Token(.function, "all")))
        #expect(t.contains(Token(.variable, "$(CC)")))
        #expect(t.contains(Token(.variable, "$@")))
    }

    @Test func languageDetection() {
        #expect(Language.forFileName("Makefile")?.id == "makefile")
        #expect(Language.forFileName("Dockerfile.dev")?.id == "dockerfile")
        #expect(Language.forFileName("main.rs")?.id == "rust")
        #expect(Language.forFileName(".zshrc")?.id == "shell")
        #expect(Language.forFileName("App.tsx")?.id == "typescript")
        #expect(Language.forShebang("#!/usr/bin/env python3")?.id == "python")
        #expect(Language.forShebang("#!/bin/bash -e")?.id == "shell")
        #expect(Language.named("C++")?.id == "cpp")
        #expect(Language.named("js")?.id == "javascript")
        #expect(Language.named("{.ruby}")?.id == "ruby")
        #expect(Language.all.count >= 30)
    }

    @Test func listingLinesAndEscaping() {
        let html = CodeRenderer.listing(SyntaxHighlighter.tokenize("a < b\n\n/* x\ny */\n", language: .c), lineNumbers: true, wrap: true)
        #expect(html.hasPrefix("<div class=\"code ln wrap\">"))
        #expect(html.components(separatedBy: "class=\"l\"").count - 1 == 4)
        #expect(html.contains("a &lt; b"))
        #expect(html.contains("data-n=\"4\"><span class=\"c\"><span class=\"com\">y */</span>"))
        let plain = CodeRenderer.listing([Token(.plain, "")], lineNumbers: false, wrap: false)
        #expect(plain.components(separatedBy: "class=\"l\"").count - 1 == 1)
    }
}
