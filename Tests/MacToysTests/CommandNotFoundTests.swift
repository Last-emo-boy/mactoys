import Foundation
import Testing
@testable import CommandNotFound

@Suite struct CommandNotFoundTests {
    static let index = """
    a2ps:a2ps a2ps-lpr-wrapper card composeglyphs fixps lp2 ogonkify pdiff
    git:git git-cvsserver git-receive-pack git-shell git-upload-archive git-upload-pack scalar
    git-lfs(3.5.1):git-lfs
    imagemagick:animate compare composite conjure convert display identify import magick mogrify montage stream
    graphicsmagick:gm convert
    node:node npm npx
    wget:wget
    broken line without colon
    :nothing
    empty:
    """

    @Test func parsesBothLineFormats() {
        let map = CNFIndex.parse(Self.index)
        #expect(map["git-lfs"] == ["git-lfs"], "formula(version): prefix is stripped")
        #expect(map["npx"] == ["node"])
        #expect(map["convert"] == ["imagemagick", "graphicsmagick"])
        #expect(map["nothing"] == nil && map[""] == nil)
        #expect(CNFIndex.entry("wget:wget\r") ?? ("", []) == ("wget", ["wget"]))
        #expect(CNFIndex.entry("empty:") == nil)
        #expect(CNFIndex.formulaCount(Self.index) == 7)
    }

    @Test func looksUpWholeExecutableNames() {
        #expect(CNFIndex.formulae(for: "wget", in: Self.index) == ["wget"])
        #expect(CNFIndex.formulae(for: "convert", in: Self.index) == ["imagemagick", "graphicsmagick"])
        #expect(CNFIndex.formulae(for: "git", in: Self.index) == ["git"], "git-lfs doesn't match git")
        #expect(CNFIndex.formulae(for: "lfs", in: Self.index).isEmpty)
        #expect(CNFIndex.formulae(for: "scalar", in: Self.index) == ["git"], "last word on a line")
        #expect(CNFIndex.formulae(for: "a2ps", in: Self.index) == ["a2ps"], "first word on a line")
        #expect(CNFIndex.formulae(for: "", in: Self.index).isEmpty)
        #expect(CNFIndex.formulae(for: "../etc", in: Self.index).isEmpty)
        #expect(CNFIndex.formulae(for: "a b", in: Self.index).isEmpty)
    }

    @Test func validatesDownloads() {
        let good = (0..<100).map { "f\($0):e\($0) x\($0)" }.joined(separator: "\n")
        #expect(CNFIndex.looksValid(good))
        #expect(!CNFIndex.looksValid("<html><body>Not Found</body></html>"))
        #expect(!CNFIndex.looksValid(Self.index), "too short to be the real database")
    }

    @Test func readsOCIManifests() {
        let manifest = Data("""
        {"schemaVersion":2,"layers":[{"mediaType":"text/plain","digest":"sha256:abc","size":1,"annotations":{"org.opencontainers.image.title":"executables.txt"}}]}
        """.utf8)
        #expect(CNFUpdater.layerDigest(manifest) == "sha256:abc")
        #expect(CNFUpdater.layerDigest(Data("{}".utf8)) == nil)
    }

    // MARK: zshrc

    @Test func installsAndRemovesTheHandlerBlock() {
        let zshrc = "export PATH=\"$HOME/bin:$PATH\"\nalias ll='ls -l'\n"
        let helper = "/Applications/MacToys.app/Contents/Helpers/mactoys"
        let installed = CNFShell.block.insert(CNFShell.handlerLines(helper: helper), into: zshrc)
        #expect(installed.hasPrefix(zshrc + "\n# >>> MacToys Command Not Found >>>\n"))
        #expect(installed.contains("command_not_found_handler() {"))
        #expect(installed.contains("  local helper='/Applications/MacToys.app/Contents/Helpers/mactoys'"))
        #expect(installed.contains("    \"$helper\" cnf \"$1\""))
        #expect(installed.hasSuffix("# <<< MacToys Command Not Found <<<\n"))
        #expect(CNFShell.installedHelper(in: installed) == helper)
        #expect(CNFShell.block.remove(from: installed) == zshrc)
        // Reinstalling with another path replaces the block instead of adding a second one.
        let moved = CNFShell.block.insert(CNFShell.handlerLines(helper: "/Users/me/Applications/MacToys.app/Contents/Helpers/mactoys"), into: installed)
        #expect(moved.components(separatedBy: "command_not_found_handler() {").count == 2)
        #expect(CNFShell.installedHelper(in: moved) == "/Users/me/Applications/MacToys.app/Contents/Helpers/mactoys")
    }

    @Test func quotesHelperPaths() {
        let odd = "/Users/o'neil/Apps/MacToys.app/Contents/Helpers/mactoys"
        let text = CNFShell.block.insert(CNFShell.handlerLines(helper: odd), into: "")
        #expect(text.contains("local helper='/Users/o'\\''neil/Apps/MacToys.app/Contents/Helpers/mactoys'"))
        #expect(CNFShell.installedHelper(in: text) == odd)
    }

    @Test func removesDamagedBlocksWithoutTouchingUserLines() {
        let damaged = (["# mine", "# >>> MacToys Command Not Found >>>"] + CNFShell.handlerLines(helper: "/x") + ["  indented user line", "echo hi"])
            .joined(separator: "\n")
        #expect(CNFShell.block.remove(from: damaged) == "# mine\n  indented user line\necho hi")
    }

    @Test func detectsOtherHandlers() {
        #expect(CNFShell.otherHandlers(in: "HB_CNF_HANDLER=\"$(brew --repository)/Library/Homebrew/command-not-found/handler.sh\"\nsource $HB_CNF_HANDLER\n"))
        #expect(CNFShell.otherHandlers(in: "command_not_found_handler() { echo nope; }\n"))
        #expect(!CNFShell.otherHandlers(in: "# command_not_found_handler is nice\n"))
        let ours = CNFShell.block.insert(CNFShell.handlerLines(helper: "/x"), into: "alias g=git\n")
        #expect(!CNFShell.otherHandlers(in: ours), "our own block doesn't count")
        #expect(CNFShell.installedHelper(in: "no block") == nil)
    }

    @Test func runsUnderZsh() throws {
        // The generated handler is valid zsh and falls back to zsh's message without a terminal.
        let script = CNFShell.handlerLines(helper: "/nonexistent/mactoys").joined(separator: "\n") + "\ncommand_not_found_handler frobnicate\nexit $?"
        let r = Process()
        r.executableURL = URL(fileURLWithPath: "/bin/zsh")
        r.arguments = ["-f", "-c", script]
        let err = Pipe()
        r.standardError = err
        r.standardOutput = Pipe()
        try r.run()
        r.waitUntilExit()
        #expect(r.terminationStatus == 127)
        #expect(String(decoding: err.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self) == "zsh: command not found: frobnicate\n")
    }

    // MARK: Messages

    @Test func suggestsFormulae() {
        let one = CommandNotFound.suggestions(for: "wget", index: Self.index, installed: { _ in false })
        #expect(one == [CommandNotFound.Suggestion(formula: "wget", installCommand: "brew install wget", isInstalled: false)])
        #expect(CommandNotFound.message(for: "wget", suggestions: one, brewInstalled: true) == """
        zsh: command not found: wget
        The command 'wget' is provided by this Homebrew formula:
          brew install wget
        """)
        let two = CommandNotFound.suggestions(for: "convert", index: Self.index, installed: { _ in false })
        let text = CommandNotFound.message(for: "convert", suggestions: two, brewInstalled: false)
        #expect(text.contains("these Homebrew formulae:\n  brew install imagemagick\n  brew install graphicsmagick"))
        #expect(text.hasSuffix("Homebrew isn't installed; get it at https://brew.sh"))
        #expect(CommandNotFound.message(for: "zzz", suggestions: [], brewInstalled: true) == "zsh: command not found: zzz")
    }

    @Test func pointsAtUnlinkedInstalledFormulae() {
        let s = CommandNotFound.suggestions(for: "node", index: Self.index, installed: { $0 == "node" })
        let text = CommandNotFound.message(for: "node", suggestions: s, brewInstalled: true)
        #expect(text.contains("installed but not linked"))
        #expect(text.contains("brew link node"))
    }
}
