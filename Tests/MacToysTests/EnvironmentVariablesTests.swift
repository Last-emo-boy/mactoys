import Foundation
import Testing
@testable import EnvironmentVariables

@Suite struct EnvironmentVariablesTests {
    let block = ManagedBlock(name: "Environment Variables")
    let body = ["# Managed by MacToys", "[[ -r \"$HOME/env.zsh\" ]] && source \"$HOME/env.zsh\""]

    // MARK: Managed block

    @Test func insertsIntoEmptyFile() {
        let out = block.insert(body, into: "")
        #expect(out == "# >>> MacToys Environment Variables >>>\n" + body.joined(separator: "\n") + "\n# <<< MacToys Environment Variables <<<\n")
        #expect(block.remove(from: out) == "")
    }

    @Test func appendsAfterUserContentAndRemovesCleanly() {
        let original = "export FOO=1\n# my stuff\n"
        let out = block.insert(body, into: original)
        #expect(out.hasPrefix(original + "\n# >>> MacToys"))
        #expect(block.body(in: out) == body)
        #expect(block.remove(from: out) == original, "insert then remove is byte-identical")
    }

    @Test func fileWithoutTrailingNewline() {
        let out = block.insert(body, into: "export FOO=1")
        #expect(out.hasPrefix("export FOO=1\n\n# >>> MacToys"))
        #expect(block.remove(from: out) == "export FOO=1\n")
    }

    @Test func replacesExistingBlockInPlace() {
        let original = "a\n# >>> MacToys Environment Variables >>>\nold line\n# <<< MacToys Environment Variables <<<\nb\n"
        let out = block.insert(["new line"], into: original)
        #expect(out == "a\n# >>> MacToys Environment Variables >>>\nnew line\n# <<< MacToys Environment Variables <<<\nb\n")
        #expect(block.insert(["new line"], into: out) == out, "idempotent")
        #expect(block.remove(from: out) == "a\nb\n")
    }

    @Test func collapsesDuplicateBlocks() {
        let original = """
        a
        # >>> MacToys Environment Variables >>>
        one
        # <<< MacToys Environment Variables <<<
        b
        # >>> MacToys Environment Variables >>>
        two
        # <<< MacToys Environment Variables <<<
        c
        """
        let out = block.insert(["x"], into: original)
        #expect(out == "a\n# >>> MacToys Environment Variables >>>\nx\n# <<< MacToys Environment Variables <<<\nb\nc")
        #expect(out.components(separatedBy: "# >>> MacToys").count == 2)
    }

    @Test func toleratesUnclosedBlock() {
        let original = "a\n# >>> MacToys Environment Variables >>>\n[[ -r x ]] && source \"$HOME/Library/Application Support/MacToys/envvars/env.zsh\"\nb\n"
        #expect(block.remove(from: original) == "a\nb\n", "user line after a broken block survives")
        let out = block.insert(["x"], into: original)
        #expect(out == "a\n# >>> MacToys Environment Variables >>>\nx\n# <<< MacToys Environment Variables <<<\nb\n")
    }

    @Test func leavesFilesWithoutBlockUntouched() {
        let original = "# >>> conda initialize >>>\nstuff\n# <<< conda initialize <<<\n"
        #expect(block.remove(from: original) == original)
        #expect(!block.contains(original))
    }

    // MARK: Quoting

    @Test func quotesForZsh() {
        #expect(ZshQuote.quote("nvim", pathLike: false) == "\"nvim\"")
        #expect(ZshQuote.quote("say \"hi\"", pathLike: false) == "\"say \\\"hi\\\"\"")
        #expect(ZshQuote.quote("C:\\dir", pathLike: false) == "\"C:\\\\dir\"")
        #expect(ZshQuote.quote("`id`", pathLike: false) == "\"\\`id\\`\"")
        #expect(ZshQuote.quote("$HOME/go", pathLike: false) == "\"$HOME/go\"")
        #expect(ZshQuote.quote("${XDG_CONFIG_HOME}/x", pathLike: false) == "\"${XDG_CONFIG_HOME}/x\"")
        #expect(ZshQuote.quote("$(rm -rf ~)", pathLike: false) == "\"\\$(rm -rf ~)\"")
        #expect(ZshQuote.quote("costs $5", pathLike: false) == "\"costs \\$5\"")
        #expect(ZshQuote.quote("end$", pathLike: false) == "\"end\\$\"")
        #expect(ZshQuote.quote("multi\nline", pathLike: false) == "\"multi\nline\"")
    }

    @Test func expandsTildeOnlyAtSegmentStart() {
        #expect(ZshQuote.quote("~/bin", pathLike: false) == "\"$HOME/bin\"")
        #expect(ZshQuote.quote("~", pathLike: false) == "\"$HOME\"")
        #expect(ZshQuote.quote("~/a:~/b:$PATH", pathLike: true) == "\"$HOME/a:$HOME/b:$PATH\"")
        #expect(ZshQuote.quote("~/a:~/b", pathLike: false) == "\"$HOME/a:~/b\"")
        #expect(ZshQuote.quote("~root/x", pathLike: false) == "\"~root/x\"")
        #expect(ZshQuote.quote("a~b", pathLike: false) == "\"a~b\"")
        #expect(ZshQuote.single("it's") == "'it'\\''s'")
    }

    // MARK: PATH lists

    @Test func removesDuplicatePathEntriesKeepingFirst() {
        let entries = ["/opt/homebrew/bin", "~/.local/bin", "/usr/local/bin", "/opt/homebrew/bin/", "/Users/me/.local/bin",
                       "$HOME/.local/bin", "/USR/LOCAL/BIN", "", "$PATH", "/opt//homebrew/bin"]
        #expect(PathList.duplicateIndices(entries, home: "/Users/me") == [3, 4, 5, 6, 9])
        #expect(PathList.removeDuplicates(entries, home: "/Users/me") == ["/opt/homebrew/bin", "~/.local/bin", "/usr/local/bin", "$PATH"])
    }

    @Test func splitsAndJoins() {
        #expect(PathList.split("") == [])
        #expect(PathList.split("/a:/b") == ["/a", "/b"])
        #expect(PathList.join(["/a", "/b"]) == "/a:/b")
        #expect(PathList.key("/", home: "/h") == "/")
    }

    // MARK: Composition and files

    @Test func profileOverridesUserVariables() {
        let user = [EnvVariable(name: "EDITOR", value: "vim"), EnvVariable(name: "PATH", value: "/u:$PATH"),
                    EnvVariable(name: "LANG", value: "en_US.UTF-8"), EnvVariable(name: "", value: "ignored"),
                    EnvVariable(name: "LANG", value: "dup")]
        let profile = EnvProfile(name: "Py", variables: [EnvVariable(name: "PATH", value: "/py:$PATH"),
                                                         EnvVariable(name: "PYENV_VERSION", value: "3.13")])
        let eff = EnvComposer.effective(user: user, profile: profile)
        #expect(eff.map(\.name) == ["EDITOR", "LANG", "PATH", "PYENV_VERSION"])
        #expect(eff.first { $0.name == "PATH" }?.value == "/py:$PATH")
        #expect(eff.first { $0.name == "PATH" }?.source == .profile)
        #expect(eff.first { $0.name == "LANG" }?.value == "en_US.UTF-8")
        #expect(EnvComposer.effective(user: user, profile: nil).map(\.name) == ["EDITOR", "PATH", "LANG"])
    }

    @Test func appliedProfileComesFromSettings() {
        var s = EnvSettings()
        let p = EnvProfile(name: "Node", variables: [EnvVariable(name: "NODE_ENV", value: "development")])
        s.profiles = [p, EnvProfile(name: "Other", variables: [EnvVariable(name: "X", value: "1")])]
        #expect(EnvComposer.effective(s).isEmpty)
        s.appliedProfile = p.id
        #expect(EnvComposer.effective(s).map(\.name) == ["NODE_ENV"])
    }

    @Test func validatesNames() {
        #expect(EnvNames.problem("EDITOR") == nil)
        #expect(EnvNames.problem("_PRIVATE1") == nil)
        #expect(EnvNames.problem("1ABC") != nil)
        #expect(EnvNames.problem("MY-VAR") != nil)
        #expect(EnvNames.problem("") != nil)
        #expect(EnvNames.problem("HOME") != nil)
        #expect(EnvNames.problem("ÜBER") != nil)
        #expect(EnvComposer.problems([EffectiveVariable(name: "SHELL", value: "/bin/sh", source: .user)]).count == 1)
        #expect(EnvNames.isPathLike("PATH") && EnvNames.isPathLike("PKG_CONFIG_PATH") && !EnvNames.isPathLike("EDITOR"))
    }

    @Test func zshFileExportsInOrderAndDedupesPaths() {
        let vars = [EffectiveVariable(name: "EDITOR", value: "nvim", source: .user),
                    EffectiveVariable(name: "PATH", value: "~/bin:$PATH", source: .profile)]
        let text = EnvFiles.zshFile(vars, profileName: "Py")
        let lines = text.components(separatedBy: "\n")
        #expect(lines.contains("export EDITOR=\"nvim\""))
        #expect(lines.contains("export PATH=\"$HOME/bin:$PATH\""))
        #expect(lines.contains("export PATH=\"${(j.:.)${(@u)${(s.:.)PATH}}}\""))
        #expect(lines.firstIndex(of: "export EDITOR=\"nvim\"")! < lines.firstIndex(of: "export PATH=\"$HOME/bin:$PATH\"")!)
        #expect(text.hasSuffix("\n"))
    }

    @Test func sourceLinesUseHomeRelativePath() {
        let applier = EnvApplier(home: URL(fileURLWithPath: "/Users/me"),
                                 dataDirectory: URL(fileURLWithPath: "/Users/me/Library/Application Support/MacToys/envvars"))
        #expect(applier.envFileReference == "$HOME/Library/Application Support/MacToys/envvars/env.zsh")
        let lines = EnvFiles.sourceLines(envFile: applier.envFileReference, loginPhase: true)
        #expect(lines[1] == "[[ -r \"$HOME/Library/Application Support/MacToys/envvars/env.zsh\" ]] && MACTOYS_ENV_PHASE=login source \"$HOME/Library/Application Support/MacToys/envvars/env.zsh\"")
    }

    @Test func expandsForLaunchd() {
        let env = ["PATH": "/usr/bin:/bin", "GOPATH": "/go"]
        #expect(EnvFiles.expand("$GOPATH/bin:${PATH}", environment: env, home: "/Users/me", pathLike: true) == "/go/bin:/usr/bin:/bin")
        #expect(EnvFiles.expand("~/x:~/y", environment: env, home: "/Users/me", pathLike: true) == "/Users/me/x:/Users/me/y")
        #expect(EnvFiles.expand("$MISSING-x", environment: env, home: "/h", pathLike: false) == "-x")
        #expect(EnvFiles.expand("$HOME/a", environment: [:], home: "/h", pathLike: false) == "/h/a")
        #expect(EnvFiles.expand("cost $5 $(x)", environment: env, home: "/h", pathLike: false) == "cost $5 $(x)")
        let values = EnvFiles.launchdValues([
            EffectiveVariable(name: "TOOLS", value: "~/tools", source: .user),
            EffectiveVariable(name: "PATH", value: "$TOOLS/bin:/usr/bin:$PATH", source: .profile),
        ], base: ["PATH": "/usr/bin:/bin"], home: "/Users/me")
        #expect(values.map(\.1) == ["/Users/me/tools", "/Users/me/tools/bin:/usr/bin:/bin"])
    }

    @Test func launchdScriptQuotesValues() {
        let script = EnvFiles.launchdScript(set: [("GREETING", "it's ok")], unset: ["OLD"])
        #expect(script == "/bin/launchctl setenv GREETING 'it'\\''s ok'; /bin/launchctl unsetenv OLD")
    }

    @Test func parsesEnvironmentDumps() {
        let env0 = EnvFiles.parseEnv0("A=1\0B=x=y\0MULTI=a\nb\0bogus\0")
        #expect(env0.map(\.0) == ["A", "B", "MULTI"])
        #expect(env0[1].1 == "x=y" && env0[2].1 == "a\nb")
        let print = """
        gui/501 = {
        	type = gui
        	environment = {
        		PATH => /opt/homebrew/bin:/usr/bin
        		EDITOR => nvim
        	}
        	services = {
        		0 - com.apple.x => thing
        	}
        }
        """
        #expect(EnvFiles.parseLaunchctlPrint(print) == ["PATH": "/opt/homebrew/bin:/usr/bin", "EDITOR": "nvim"])
    }

    // MARK: Applier (temporary home, fake launchctl)

    final class FakeLaunchd: @unchecked Sendable {
        var env: [String: String] = [:]
        var bootedOut: [String] = []
        var launchctl: Launchctl {
            Launchctl(get: { self.env[$0] }, set: { self.env[$0] = $1; return true },
                      unset: { self.env[$0] = nil; return true }, bootout: { self.bootedOut.append($0) })
        }
    }

    static func tempHome() throws -> URL {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("envvars-test-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    @Test func appliesAndUninstalls() throws {
        let home = try Self.tempHome()
        defer { try? FileManager.default.removeItem(at: home) }
        let applier = EnvApplier(home: home, dataDirectory: home.appendingPathComponent("data"))
        let originalZshenv = "export KEEP=me\n"
        try originalZshenv.write(to: applier.zshenv, atomically: true, encoding: .utf8)
        let fake = FakeLaunchd()
        fake.env["EDITOR"] = "vi"

        var s = EnvSettings()
        s.userVariables = [EnvVariable(name: "EDITOR", value: "nvim"), EnvVariable(name: "PATH", value: "~/bin:$PATH")]
        let warnings = try applier.apply(&s, launchctl: fake.launchctl)
        #expect(warnings.isEmpty)

        let zshenv = try String(contentsOf: applier.zshenv, encoding: .utf8)
        #expect(zshenv.hasPrefix(originalZshenv))
        #expect(EnvFiles.block.contains(zshenv))
        #expect(applier.isInstalled)
        let zprofile = try String(contentsOf: applier.zprofile, encoding: .utf8)
        #expect(zprofile.contains("MACTOYS_ENV_PHASE=login"), "PATH-like variables re-apply after path_helper")
        let envFile = try String(contentsOf: applier.envFile, encoding: .utf8)
        #expect(envFile.contains("export EDITOR=\"nvim\""))
        #expect(fake.env["EDITOR"] == "nvim")
        #expect(fake.env["PATH"] == home.path + "/bin:/usr/bin:/bin:/usr/sbin:/sbin")
        #expect(s.launchdOriginals["EDITOR"] == .some("vi"))
        #expect(s.launchdOriginals["PATH"] == .some(nil))
        #expect(FileManager.default.fileExists(atPath: applier.launchAgent.path))
        #expect(s.lastApplied?.count == 2)
        let backups = try FileManager.default.contentsOfDirectory(atPath: applier.backupDirectory.path)
        #expect(backups.count == 1 && backups[0].hasPrefix("zshenv-"), "zshenv backed up; zprofile didn't exist")

        // Dropping EDITOR restores launchd's original value; applying again doesn't back up again.
        s.userVariables.removeFirst()
        _ = try applier.apply(&s, launchctl: fake.launchctl)
        #expect(fake.env["EDITOR"] == "vi")
        #expect(s.launchdOriginals["EDITOR"] == nil)
        #expect(try FileManager.default.contentsOfDirectory(atPath: applier.backupDirectory.path).count == 1)

        _ = try applier.uninstall(&s, launchctl: fake.launchctl)
        #expect(try String(contentsOf: applier.zshenv, encoding: .utf8) == originalZshenv)
        #expect(fake.env["PATH"] == nil)
        #expect(!FileManager.default.fileExists(atPath: applier.launchAgent.path))
        #expect(!FileManager.default.fileExists(atPath: applier.envFile.path))
        #expect(fake.bootedOut == [EnvFiles.agentLabel])
    }

    @Test func editsSymlinkedDotfileInPlace() throws {
        let home = try Self.tempHome()
        defer { try? FileManager.default.removeItem(at: home) }
        let dotfiles = home.appendingPathComponent("dotfiles")
        try FileManager.default.createDirectory(at: dotfiles, withIntermediateDirectories: true)
        let real = dotfiles.appendingPathComponent("zshenv")
        try "export A=1\n".write(to: real, atomically: true, encoding: .utf8)
        let applier = EnvApplier(home: home, dataDirectory: home.appendingPathComponent("data"))
        try FileManager.default.createSymbolicLink(at: applier.zshenv, withDestinationURL: real)

        var s = EnvSettings()
        s.applyToLaunchd = false
        s.userVariables = [EnvVariable(name: "EDITOR", value: "nvim")]
        _ = try applier.apply(&s, launchctl: FakeLaunchd().launchctl)
        let attrs = try FileManager.default.attributesOfItem(atPath: applier.zshenv.path)
        #expect(attrs[.type] as? FileAttributeType == .typeSymbolicLink, "the symlink is kept")
        #expect(EnvFiles.block.contains(try String(contentsOf: real, encoding: .utf8)))
        #expect(!FileManager.default.fileExists(atPath: applier.zprofile.path), "no PATH-like variables, no .zprofile")
    }

    @Test func refusesReservedNames() throws {
        let home = try Self.tempHome()
        defer { try? FileManager.default.removeItem(at: home) }
        let applier = EnvApplier(home: home, dataDirectory: home.appendingPathComponent("data"))
        var s = EnvSettings()
        s.userVariables = [EnvVariable(name: "HOME", value: "/tmp")]
        #expect(throws: EnvApplier.Failure.self) { try applier.apply(&s, launchctl: FakeLaunchd().launchctl) }
        #expect(!FileManager.default.fileExists(atPath: applier.zshenv.path), "nothing written")
    }

    @Test @MainActor func deduplicatesOnlyPathLikeVariables() {
        let vars = [EnvVariable(name: "PATH", value: "/a:/b:/a/"), EnvVariable(name: "LIST", value: "x:x")]
        let out = EnvironmentVariablesModule.deduplicated(vars)
        #expect(out[0].value == "/a:/b")
        #expect(out[1].value == "x:x")
    }
}
