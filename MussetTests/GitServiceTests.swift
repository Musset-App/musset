import XCTest
@testable import Musset

/// Git through libgit2: no git binary involved.
final class GitServiceTests: XCTestCase {
    var tmp: URL!
    var git: GitService!

    override func setUpWithError() throws {
        tmp = FileManager.default.temporaryDirectory.appendingPathComponent("musset-git-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        git = GitService(root: tmp)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: tmp)
    }

    private func write(_ path: String, _ text: String) throws {
        let u = tmp.appendingPathComponent(path)
        try FileManager.default.createDirectory(at: u.deletingLastPathComponent(), withIntermediateDirectories: true)
        try text.write(to: u, atomically: true, encoding: .utf8)
    }

    func testInitCommitAndHistory() throws {
        XCTAssertFalse(git.isRepo)
        try git.initRepo()
        XCTAssertTrue(git.isRepo)
        XCTAssertTrue(git.log(path: "01.md").isEmpty)

        try write("01.md", "# Un\n\nPremière phrase.\n")
        try write(".musset/book.json", "{}")
        XCTAssertTrue(try git.commit(paths: ["01.md", ".musset"], message: "musset: new book"))
        // Nothing changed: no empty commit.
        XCTAssertFalse(try git.commit(paths: ["01.md", ".musset"], message: "musset: again"))

        try write("01.md", "# Un\n\nPremière phrase, revue.\n")
        XCTAssertTrue(try git.commit(paths: ["01.md"], message: "musset: autosave"))

        let log = git.log(path: "01.md")
        XCTAssertEqual(log.map(\.subject), ["musset: autosave", "musset: new book"])
        XCTAssertEqual(log[0].id.count, 40)
        XCTAssertEqual(git.show(log[1].id, path: "01.md"), "# Un\n\nPremière phrase.\n")
        XCTAssertEqual(git.show(log[1].short, path: "01.md"), "# Un\n\nPremière phrase.\n")
        XCTAssertEqual(git.show(log[0].id, path: ".musset/book.json"), "{}")
        XCTAssertNil(git.show(log[0].id, path: "absent.md"))
        // Only the book.json commit touched .musset.
        XCTAssertEqual(git.log(path: ".musset/book.json").map(\.subject), ["musset: new book"])
    }

    func testCommitsOnlyTheGivenPaths() throws {
        try git.initRepo()
        try write("01.md", "a")
        try write("notes-perso.txt", "private")
        XCTAssertTrue(try git.commit(paths: ["01.md"], message: "one"))
        let c = git.log(path: "01.md")[0]
        XCTAssertEqual(git.show(c.id, path: "01.md"), "a")
        XCTAssertNil(git.show(c.id, path: "notes-perso.txt"))
        // Paths that don't exist yet are fine.
        XCTAssertFalse(try git.commit(paths: ["missing.md"], message: "none"))
    }

    func testDeletedFileIsCommitted() throws {
        try git.initRepo()
        try write(".musset/a.json", "1")
        try write(".musset/b.json", "2")
        try git.commit(paths: [".musset"], message: "add")
        try FileManager.default.removeItem(at: tmp.appendingPathComponent(".musset/b.json"))
        XCTAssertTrue(try git.commit(paths: [".musset"], message: "remove b"))
        XCTAssertNil(git.show("HEAD", path: ".musset/b.json"))
        XCTAssertEqual(git.show("HEAD", path: ".musset/a.json"), "1")
        XCTAssertEqual(git.show("HEAD~1", path: ".musset/b.json"), "2")
    }

    func testHistoryFollowsRenames() throws {
        try git.initRepo()
        let text = (1...40).map { "Ligne \($0) d’un chapitre assez long pour être reconnu." }.joined(separator: "\n") + "\n"
        try write("old.md", text)
        try git.commit(paths: ["old.md"], message: "create")
        try FileManager.default.moveItem(at: tmp.appendingPathComponent("old.md"), to: tmp.appendingPathComponent("new.md"))
        try git.commit(paths: ["old.md", "new.md"], message: "rename")
        try write("new.md", text + "Une ligne de plus.\n")
        try git.commit(paths: ["new.md"], message: "edit")
        XCTAssertEqual(git.log(path: "new.md").map(\.subject), ["edit", "rename", "create"])
    }

    func testWordDiffAgainstWorkingTree() throws {
        try git.initRepo()
        try write("01.md", "Il pleuvait sur la ville.\n")
        try git.commit(paths: ["01.md"], message: "one")
        let c = git.log(path: "01.md")[0]
        func wordDiff() throws -> String { Diff.words(git.show(c.id, path: "01.md") ?? "", try String(contentsOf: tmp.appendingPathComponent("01.md"), encoding: .utf8)) }
        XCTAssertEqual(try wordDiff(), "")
        try write("01.md", "Il neigeait sur la ville.\n")
        let diff = try wordDiff()
        XCTAssertTrue(diff.hasSuffix("Il [-pleuvait-]{+neigeait+} sur la ville.\n"), diff)
        XCTAssertEqual(WordDiff.stats(diff).added, 1)
        XCTAssertEqual(WordDiff.stats(diff).removed, 1)
    }

    func testWordDiffOfTexts() {
        XCTAssertEqual(Diff.words("a b c", "a b c"), "")
        func body(_ a: String, _ b: String) -> String {
            String(Diff.words(a, b).split(separator: "\n", maxSplits: 1, omittingEmptySubsequences: false)[1])
        }
        XCTAssertEqual(body("foo bar baz", "foo baz"), "foo [-bar-] baz")
        XCTAssertEqual(body("foo baz", "foo bar baz"), "foo {+bar+} baz")
        XCTAssertEqual(body("bar baz", "baz"), "[-bar-] baz")
        XCTAssertEqual(body("un deux trois quatre", "un cinq six quatre"), "un [-deux trois-]{+cinq six+} quatre")
        XCTAssertEqual(String(WordDiff.attributed(Diff.words("un deux", "un trois")).characters), "un deuxtrois")
    }

    func testBranchesAndRemotes() throws {
        try git.initRepo()
        XCTAssertNil(git.currentBranch)
        try write("01.md", "a")
        try git.commit(paths: ["01.md"], message: "one")
        let main = try XCTUnwrap(git.currentBranch)
        try git.createBranch("relecture-marie")
        XCTAssertEqual(Set(git.branches()), [main, "relecture-marie"])
        XCTAssertEqual(git.currentBranch, main)
        XCTAssertTrue(git.remotes().isEmpty)
        try git.addRemote("origin", url: "https://forge.example/julien/livre.git")
        XCTAssertEqual(git.remotes(), ["origin": "https://forge.example/julien/livre.git"])
    }

    func testCommitThatAlsoReadsBackWithCommandLineGit() throws {
        // libgit2's repositories are ordinary git repositories.
        let cli = "/usr/bin/git"
        guard FileManager.default.isExecutableFile(atPath: "/Library/Developer/CommandLineTools/usr/bin/git")
                || FileManager.default.fileExists(atPath: "/Applications/Xcode.app") else { throw XCTSkip("no git on this Mac") }
        try git.initRepo()
        try write("01.md", "a")
        try git.commit(paths: ["01.md"], message: "musset: one")
        let r = try Shell.run(cli, ["log", "--format=%s"], cwd: tmp)
        XCTAssertEqual(r.stdout.trimmingCharacters(in: .whitespacesAndNewlines), "musset: one")
        let status = try Shell.run(cli, ["status", "--porcelain"], cwd: tmp)
        XCTAssertEqual(status.stdout, "")
    }
}
