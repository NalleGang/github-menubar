import Foundation
import XCTest
@testable import GitMenuBar

final class GitTests: XCTestCase {
    private var repo: URL!

    override func setUpWithError() throws {
        repo = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: repo, withIntermediateDirectories: false)
        try git(["init", "-b", "main"])
        try git(["config", "user.name", "Widget Test"])
        try git(["config", "user.email", "test@example.invalid"])
        try git(["config", "commit.gpgsign", "false"])
        try git(["config", "core.hooksPath", "/dev/null"])
    }

    override func tearDownWithError() throws { try FileManager.default.removeItem(at: repo) }

    @discardableResult private func git(_ args: [String]) throws -> String {
        String(decoding: try Command.run("git", ["-C", repo.path] + args), as: UTF8.self)
    }

    private func write(_ name: String, _ text: String) throws {
        try Data(text.utf8).write(to: repo.appendingPathComponent(name))
    }

    private func change(_ name: String) throws -> GitChange {
        try XCTUnwrap(Git.status(repo.path).changes.first { $0.path == name })
    }

    func testSelectiveIndexAndDiff() throws {
        let name = ":(glob)*\n[abc]"
        try write(name, "one\n")
        try write("other", "leave alone")
        try Git.stage(repo.path, change: change(name))
        XCTAssertFalse(try change("other").staged)
        try Git.unstage(repo.path, change: change(name))
        XCTAssertFalse(try change(name).staged)
        try Git.stage(repo.path, change: change(name))
        try write(name, "two\n")
        let mixed = try change(name)
        XCTAssertTrue(mixed.staged && mixed.unstaged)
        XCTAssertTrue(try Git.diff(repo.path, change: mixed, staged: true).contains("+one"))
        XCTAssertTrue(try Git.diff(repo.path, change: mixed, staged: false).contains("+two"))
        try Git.commit(repo.path, message: "first")
        XCTAssertTrue(try Git.history(repo.path).contains("first"))
        XCTAssertTrue(try change(name).unstaged)
        try git(["mv", name, "renamed"])
        let renamed = try change(name + " → renamed")
        try Git.unstage(repo.path, change: renamed)
        XCTAssertEqual(try git(["diff", "--cached", "--name-only"]), "")
        XCTAssertEqual(try String(contentsOf: repo.appendingPathComponent("renamed")), "two\n")
    }

    func testDeepNestedCheckoutAndRemovedCheckout() throws {
        let child = repo.appendingPathComponent(".hidden/a/[nested]")
        try FileManager.default.createDirectory(at: child, withIntermediateDirectories: true)
        try git(["init", child.path])
        try write(".hidden/a/[nested]/child", "private")
        try write("parent", "keep")
        try FileManager.default.createSymbolicLink(at: repo.appendingPathComponent("link"), withDestinationURL: child)
        XCTAssertEqual(Set(try Git.status(repo.path).changes.map(\.path)), ["parent", "link"])
        try Git.stage(repo.path)
        XCTAssertEqual(try git(["diff", "--cached", "--name-only"]), "link\nparent\n")
        try FileManager.default.removeItem(at: child.appendingPathComponent(".git"))
        XCTAssertThrowsError(try Git.commit(child.path, message: "wrong checkout"))
        XCTAssertThrowsError(try Git.status(child.path))
        XCTAssertEqual(try git(["diff", "--cached", "--name-only"]), "link\nparent\n")
    }

    func testFileReplacedByDirectory() throws {
        try write("folder", "original")
        try Git.stage(repo.path)
        try Git.commit(repo.path, message: "initial")
        let folder = repo.appendingPathComponent("folder")
        try FileManager.default.removeItem(at: folder)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: false)
        try write("folder/new", "new file")
        try git(["init", "folder/nested"])
        try Git.stage(repo.path, change: change("folder"))
        XCTAssertEqual(try git(["diff", "--cached", "--name-only"]), "folder\n")
        try git(["reset", "--quiet"])
        try Git.stage(repo.path)
        XCTAssertEqual(try git(["diff", "--cached", "--name-only"]), "folder\nfolder/new\n")
    }

    func testLocalRemoteSync() throws {
        let remote = repo.appendingPathComponent(".remote.git")
        let peer = repo.appendingPathComponent(".peer")
        try git(["init", "--bare", "-b", "main", remote.path])
        try git(["remote", "add", "origin", remote.path])
        try write("file", "first")
        try Git.stage(repo.path)
        try Git.commit(repo.path, message: "initial")
        try git(["push", "-u", "origin", "main"])
        try git(["clone", remote.path, peer.path])
        try write(".peer/peer", "second")
        try git(["-C", peer.path, "add", "peer"])
        try git(["-C", peer.path, "-c", "user.name=Test", "-c", "user.email=test@example.invalid", "-c", "commit.gpgsign=false", "-c", "core.hooksPath=/dev/null", "commit", "-m", "second"])
        try git(["-C", peer.path, "push"])
        try Git.sync(repo.path, action: .fetch)
        XCTAssertEqual(try Git.status(repo.path).divergence.behind, 1)
        try Git.sync(repo.path, action: .pull)
        XCTAssertTrue(try Git.history(repo.path).contains("second"))
        try write("file", "new")
        try Git.stage(repo.path, change: change("file"))
        try Git.commit(repo.path, message: "third")
        XCTAssertEqual(try Git.status(repo.path).divergence.ahead, 1)
        try Git.sync(repo.path, action: .push)
        XCTAssertEqual(try git(["rev-parse", "HEAD"]), try git(["--git-dir", remote.path, "rev-parse", "main"]))
    }
}
