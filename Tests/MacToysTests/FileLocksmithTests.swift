import Darwin
import Foundation
import Testing
@testable import FileLocksmith
@testable import MacToysCore

@Suite struct FileLocksmithTests {
    @Test func findsItselfHoldingATempFile() throws {
        let dir = try FileOpsScratch()
        let file = try dir.make("locked.txt", contents: "busy")
        let handle = try FileHandle(forReadingFrom: file)
        defer { try? handle.close() }
        let found = FileLocksmithScanner.scan(paths: [file])
        let me = try #require(found.first { $0.pid == getpid() })
        #expect(me.files.contains { $0.path == file.path && $0.kind == .openFile && $0.descriptor == handle.fileDescriptor })
        #expect(me.user == NSUserName())
        #expect(me.uid == getuid())
        #expect(me.startTime > 0)
        #expect(FileLocksmithScanner.isRunning(me))
    }

    @Test func foldersMatchEverythingInside() throws {
        let dir = try FileOpsScratch()
        let deep = try dir.make("a/b/c/deep.db")
        let handle = try FileHandle(forReadingFrom: deep)
        defer { try? handle.close() }
        let byFolder = FileLocksmithScanner.scan(paths: [dir.url.appendingPathComponent("a")])
        #expect(byFolder.contains { $0.pid == getpid() && $0.files.contains { $0.path == deep.path } })
        // A sibling folder with a common prefix doesn't match.
        try FileManager.default.createDirectory(at: dir.url.appendingPathComponent("a2"), withIntermediateDirectories: true)
        let sibling = FileLocksmithScanner.scan(paths: [dir.url.appendingPathComponent("a2")])
        #expect(!sibling.contains { $0.pid == getpid() && $0.files.contains { $0.path == deep.path } })
    }

    @Test func symlinkedPathsAreResolved() throws {
        let dir = try FileOpsScratch()
        let file = try dir.make("real/file.txt")
        let link = dir.url.appendingPathComponent("link")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: dir.url.appendingPathComponent("real"))
        let handle = try FileHandle(forReadingFrom: file)
        defer { try? handle.close() }
        let found = FileLocksmithScanner.scan(paths: [link])
        #expect(found.contains { $0.pid == getpid() && $0.files.contains { $0.path == file.path } })
    }

    @Test func childWorkingDirectoryAndProgramAreFound() throws {
        let dir = try FileOpsScratch()
        let work = dir.url.appendingPathComponent("work", isDirectory: true)
        try FileManager.default.createDirectory(at: work, withIntermediateDirectories: true)
        let tool = dir.url.appendingPathComponent("tools/mt-sleep")
        try FileManager.default.createDirectory(at: tool.deletingLastPathComponent(), withIntermediateDirectories: true)
        try FileManager.default.copyItem(at: URL(fileURLWithPath: "/bin/sleep"), to: tool)

        let child = Process()
        child.executableURL = tool
        child.arguments = ["30"]
        child.currentDirectoryURL = work
        try child.run()
        defer { child.terminate(); child.waitUntilExit() }
        // Wait until the child runs the copied program.
        var found: LockingProcess?
        for _ in 0..<50 {
            found = FileLocksmithScanner.scan(paths: [dir.url]).first { $0.pid == child.processIdentifier }
            if found?.files.contains(where: { $0.kind == .executable }) == true { break }
            usleep(20_000)
        }
        let p = try #require(found)
        #expect(p.files.contains { $0.kind == .workingDirectory && $0.path == work.path })
        #expect(p.files.contains { $0.kind == .executable && $0.path == tool.path })
        #expect(p.executablePath == tool.path)
        #expect(p.name == "mt-sleep")

        child.terminate()
        child.waitUntilExit()
        #expect(!FileLocksmithScanner.isRunning(p))
        #expect(FileLocksmithScanner.scan(paths: [dir.url]).allSatisfy { $0.pid != p.pid })
    }

    @Test func nothingFoundForUnusedFiles() throws {
        let dir = try FileOpsScratch()
        let idle = try dir.make("idle.txt")
        #expect(FileLocksmithScanner.scan(paths: [idle]).isEmpty)
        #expect(FileLocksmithScanner.scan(paths: []).isEmpty)
        let report = FileLocksmithScanner.scanReport(paths: [idle])
        #expect(report.processes.isEmpty)
    }

    @Test func pathMatcherBoundaries() {
        let m = PathMatcher(paths: ["/Users/me/build/", "/tmp/one.txt"])
        #expect(m.matches("/Users/me/build"))
        #expect(m.matches("/Users/me/build/x/y.o"))
        #expect(!m.matches("/Users/me/builder/y.o"))
        #expect(!m.matches("/Users/me"))
        #expect(m.matches("/tmp/one.txt"))
        #expect(!m.matches("/tmp/one.txt2"))
        #expect(!m.matches(""))
        #expect(PathMatcher(paths: ["/"]).matches("/anything"))
        #expect(PathMatcher.resolve("/tmp") == "/private/tmp")
        let both = PathMatcher([URL(fileURLWithPath: "/tmp/x")])
        #expect(both.matches("/private/tmp/x/a") && both.matches("/tmp/x/a"))
    }

    @Test func parsesLsofOutput() {
        let sample = """
        p4182
        cXcode
        u501
        Lw33d
        fcwd
        tDIR
        n/
        ftxt
        tREG
        n/Applications/Xcode.app/Contents/MacOS/Xcode
        f12r
        tREG
        n/Users/w33d/Projects/build/DerivedData/Build.db
        f13u
        tREG
        n/Users/w33d/Projects/build/DerivedData/Build.db-wal
        f14u
        tREG
        n/Users/w33d/Projects/builder/other.db
        p9921
        czsh
        u0
        Lroot
        fcwd
        tDIR
        n/Users/w33d/Projects/build
        f3u
        tIPv4
        n127.0.0.1:5000
        p1
        claunchd
        u0
        Lroot
        ftxt
        tREG
        n/sbin/launchd
        p77
        cmds
        u0
        f5r
        tREG
        n/Users/w33d/Projects/build/gone.txt (deleted)
        """.replacingOccurrences(of: "\n", with: "\r")
        let found = LsofParser.parse(sample, paths: [URL(fileURLWithPath: "/Users/w33d/Projects/build")])
        #expect(found.map(\.pid) == [4182, 77, 9921])
        let xcode = found[0]
        #expect(xcode.name == "Xcode" && xcode.user == "w33d" && xcode.uid == 501)
        #expect(xcode.executablePath == "/Applications/Xcode.app/Contents/MacOS/Xcode")
        #expect(xcode.files.map(\.descriptor) == [12, 13])
        #expect(xcode.files.allSatisfy { $0.kind == .openFile })
        #expect(found[2].files == [LockedFile(path: "/Users/w33d/Projects/build", kind: .workingDirectory)])
        #expect(found[2].user == "root")
        #expect(found[1].user == "0")
        #expect(found[1].files.first?.path == "/Users/w33d/Projects/build/gone.txt")
    }

    @Test func parsesRealLsofOutput() throws {
        let dir = try FileOpsScratch()
        let file = try dir.make("for-lsof.txt")
        let handle = try FileHandle(forReadingFrom: file)
        defer { try? handle.close() }
        let result = Shell.run("/usr/sbin/lsof", LsofParser.arguments + ["-p", String(getpid())])
        let found = LsofParser.parse(result.stdout, paths: [dir.url])
        let me = try #require(found.first { $0.pid == getpid() })
        #expect(me.files.contains { $0.path == file.path && $0.descriptor == handle.fileDescriptor })
        #expect(me.user == NSUserName())
    }

    @Test @MainActor func modelDisplayStrings() {
        let model = FileLocksmithModule.sampleModel()
        let xcode = model.processes[0]
        #expect(model.subtitle(xcode) == "PID 4182 · \(NSUserName()) · 7 files · DerivedData/Build.db")
        #expect(model.subtitle(model.processes[1]) == "PID 9921 · \(NSUserName()) · cwd")
        #expect(model.subtitle(model.processes[2]) == "PID 10233 · \(NSUserName()) · 2 files · MacToys.o")
        #expect(model.pathTitle == "~/Projects/mactoys/build")
        #expect(FileLocksmithModel.abbreviate("/etc/hosts") == "/etc/hosts")
        #expect(!model.canEnd(LockingProcess(pid: getpid(), name: "me", executablePath: nil, uid: 0, user: "", startTime: 0, files: [])))
    }

    @Test func settingsRoundTrip() throws {
        var s = FileLocksmithSettings()
        s.finderMenuNeedsOption = true
        s.activation = Shortcut(37, [.control, .option])
        #expect(try JSONDecoder().decode(FileLocksmithSettings.self, from: JSONEncoder().encode(s)) == s)
    }
}
