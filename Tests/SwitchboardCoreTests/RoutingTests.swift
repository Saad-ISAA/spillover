import Foundation
import XCTest

@testable import SwitchboardCore

final class PathNormalizerTests: XCTestCase {
    func testRejectsRelativeEmptyAndNUL() {
        XCTAssertNil(PathNormalizer.normalize("", caseInsensitive: true))
        XCTAssertNil(PathNormalizer.normalize("relative/path", caseInsensitive: true))
        XCTAssertNil(PathNormalizer.normalize("/a\0b", caseInsensitive: true))
        XCTAssertNil(PathNormalizer.normalize("~/x", caseInsensitive: true, home: nil))
    }

    func testLexicalCleanupOnMissingPaths() {
        let n = PathNormalizer.normalize(
            "/definitely-missing-root/./a//b/../c/", caseInsensitive: false)
        XCTAssertEqual(n?.display, "/definitely-missing-root/a/c")
    }

    func testTildeExpansion() {
        let n = PathNormalizer.normalize("~/proj", caseInsensitive: false, home: "/definitely-missing-home")
        XCTAssertEqual(n?.display, "/definitely-missing-home/proj")
    }

    func testCaseInsensitiveKey() {
        let n = PathNormalizer.normalize("/Missing-Root/Work", caseInsensitive: true)
        XCTAssertEqual(n?.display, "/Missing-Root/Work")
        XCTAssertEqual(n?.key, "/missing-root/work")
    }

    func testUnicodeIsNormalisedToNFC() {
        let decomposed = PathNormalizer.normalize("/missing-root/Cafe\u{301}", caseInsensitive: false)
        let composed = PathNormalizer.normalize("/missing-root/Caf\u{E9}", caseInsensitive: false)
        XCTAssertEqual(decomposed, composed)
    }

    func testSymlinksAreResolved() throws {
        let box = try Sandbox()
        let real = try box.mkdir("real/project")
        let link = box.home.appendingPathComponent("link")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: real.deletingLastPathComponent())
        let viaLink = PathNormalizer.normalize(link.path + "/project/sub", caseInsensitive: false)
        XCTAssertEqual(viaLink?.display, real.path + "/sub")
    }

    func testSpacesAndOddCharactersSurvive() {
        let raw = "/missing-root/My Project (old)/back\\slash/quote\"s"
        XCTAssertEqual(PathNormalizer.normalize(raw, caseInsensitive: false)?.display, raw)
    }

    func testRoot() {
        XCTAssertEqual(PathNormalizer.normalize("/", caseInsensitive: false)?.display, "/")
    }
}

final class RouteTableTests: XCTestCase {
    private func path(_ p: String) -> NormalizedPath {
        NormalizedPath(display: p, key: p.lowercased())
    }

    func testLongestPrefixWins() {
        let table = RouteTable(
            routes: [
                Route(folder: "/work", profileId: "a"),
                Route(folder: "/work/client", profileId: "b"),
            ], caseInsensitive: true)
        XCTAssertEqual(table.match(path("/work/client/app"))?.profileId, "b")
        XCTAssertEqual(table.match(path("/work/other"))?.profileId, "a")
        XCTAssertEqual(table.match(path("/work"))?.profileId, "a")
    }

    func testSiblingWithSharedPrefixDoesNotMatch() {
        let table = RouteTable(routes: [Route(folder: "/work", profileId: "a")], caseInsensitive: true)
        XCTAssertNil(table.match(path("/work-other")))
        XCTAssertNil(table.match(path("/wor")))
    }

    func testRootRouteCoversEverything() {
        let table = RouteTable(routes: [Route(folder: "/", profileId: "a")], caseInsensitive: true)
        XCTAssertEqual(table.match(path("/anything/at/all"))?.profileId, "a")
    }

    func testCaseInsensitiveMatching() {
        let table = RouteTable(routes: [Route(folder: "/Work", profileId: "a")], caseInsensitive: true)
        XCTAssertEqual(table.match(path("/work/x"))?.profileId, "a")
        let strict = RouteTable(routes: [Route(folder: "/Work", profileId: "a")], caseInsensitive: false)
        XCTAssertNil(strict.match(NormalizedPath(display: "/work/x", key: "/work/x")))
    }
}

final class RouteStoreTests: XCTestCase {
    func testMissingFileIsMissing() throws {
        let box = try Sandbox()
        XCTAssertEqual(RouteStore(env: box.env).load(), .missing)
    }

    func testSetReplaceAndRemove() throws {
        let box = try Sandbox()
        let folder = try box.mkdir("code/app")
        let store = RouteStore(env: box.env)
        try store.set(folder: folder.path, profileId: "a", knownProfileIDs: ["a", "b"])
        try store.set(folder: folder.path + "/", profileId: "b", knownProfileIDs: ["a", "b"])
        XCTAssertEqual(try store.routes().map(\.profileId), ["b"])
        try store.remove(folder: folder.path)
        XCTAssertEqual(try store.routes(), [])
        XCTAssertThrowsError(try store.remove(folder: folder.path))
    }

    func testValidation() throws {
        let box = try Sandbox()
        let store = RouteStore(env: box.env)
        XCTAssertThrowsError(try store.set(folder: "rel", profileId: "a", knownProfileIDs: ["a"]))
        XCTAssertThrowsError(
            try store.set(folder: box.home.path + "/nope", profileId: "a", knownProfileIDs: ["a"]))
        let folder = try box.mkdir("x")
        XCTAssertThrowsError(try store.set(folder: folder.path, profileId: "zzz", knownProfileIDs: ["a"]))
    }

    func testRoutesFileIsOwnerOnly() throws {
        let box = try Sandbox()
        let folder = try box.mkdir("x")
        try RouteStore(env: box.env).set(folder: folder.path, profileId: "a", knownProfileIDs: ["a"])
        XCTAssertEqual(SafeFS.permissions(of: box.env.paths.routesFile), 0o600)
    }

    func testCorruptFileFailsClosed() throws {
        let box = try Sandbox()
        try SafeFS.ensureDir(box.env.paths.root)
        try SafeFS.writeAtomic(Data("{not json".utf8), to: box.env.paths.routesFile)
        guard case .corrupt = RouteStore(env: box.env).load() else { return XCTFail("expected corrupt") }
    }

    func testWorldWritableFileIsInsecure() throws {
        let box = try Sandbox()
        let folder = try box.mkdir("x")
        try RouteStore(env: box.env).set(folder: folder.path, profileId: "a", knownProfileIDs: ["a"])
        try FileManager.default.setAttributes(
            [.posixPermissions: NSNumber(value: 0o666)], ofItemAtPath: box.env.paths.routesFile.path)
        guard case .insecure = RouteStore(env: box.env).load() else { return XCTFail("expected insecure") }
    }
}

final class ResolverTests: XCTestCase {
    func testNoRoutesIsUnrouted() throws {
        let box = try Sandbox()
        XCTAssertEqual(Resolver(env: box.env).resolve(cwd: box.home.path), .unrouted)
    }

    func testRoutedAndUnrouted() throws {
        let box = try Sandbox()
        let service = AppService(env: box.env)
        let work = try service.profiles.create(displayName: "Work")
        let project = try box.mkdir("projects/client")
        let other = try box.mkdir("projects/personal")
        try service.assign(folder: project.path, to: work.id)

        guard case .routed(let p, _) = Resolver(env: box.env).resolve(cwd: project.path + "/src") else {
            return XCTFail("expected routed")
        }
        XCTAssertEqual(p.id, work.id)
        XCTAssertEqual(Resolver(env: box.env).resolve(cwd: other.path), .unrouted)
    }

    func testRouteToDefaultProfile() throws {
        let box = try Sandbox()
        let project = try box.mkdir("p")
        try AppService(env: box.env).assign(folder: project.path, to: Profile.defaultID)
        guard case .routed(let p, _) = Resolver(env: box.env).resolve(cwd: project.path) else {
            return XCTFail("expected routed")
        }
        XCTAssertTrue(p.isDefault)
    }

    func testMissingProfileRefuses() throws {
        let box = try Sandbox()
        let project = try box.mkdir("p")
        try RouteStore(env: box.env).set(folder: project.path, profileId: "gone", knownProfileIDs: ["gone"])
        guard case .refused(let r) = Resolver(env: box.env).resolve(cwd: project.path) else {
            return XCTFail("expected refusal")
        }
        XCTAssertEqual(r.code, .profileMissing)
    }

    func testMissingProfileDirectoryRefuses() throws {
        let box = try Sandbox()
        let service = AppService(env: box.env)
        let work = try service.profiles.create(displayName: "Work")
        let project = try box.mkdir("p")
        try service.assign(folder: project.path, to: work.id)
        try FileManager.default.removeItem(atPath: work.configDir!)
        guard case .refused(let r) = Resolver(env: box.env).resolve(cwd: project.path) else {
            return XCTFail("expected refusal")
        }
        XCTAssertEqual(r.code, .profileDirectoryMissing)
    }

    func testCorruptRoutesRefuseEverywhere() throws {
        let box = try Sandbox()
        try SafeFS.ensureDir(box.env.paths.root)
        try SafeFS.writeAtomic(Data("garbage".utf8), to: box.env.paths.routesFile)
        guard case .refused(let r) = Resolver(env: box.env).resolve(cwd: box.home.path) else {
            return XCTFail("expected refusal")
        }
        XCTAssertEqual(r.code, .routesCorrupt)
    }
}
