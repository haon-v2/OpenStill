import Foundation
import Testing
@testable import OpenStillCore

@Suite struct UpdateCheckTests {
    private func release(_ tag: String, _ name: String? = nil, draft: Bool = false, prerelease: Bool = false) -> AppRelease {
        AppRelease(tagName: tag, name: name, htmlURL: URL(string: "https://github.com/haon-v2/OpenStill/releases/tag/\(tag)")!, draft: draft, prerelease: prerelease)
    }
    @Test func versionsComeFromTagsOrTitles() {
        #expect(UpdateCheck.version(in: "v0.8.1") == [0, 8, 1])
        #expect(UpdateCheck.version(in: "0.7.2") == [0, 7, 2])
        #expect(UpdateCheck.version(in: "OpenStill v.0.1") == [0, 1])
        #expect(UpdateCheck.version(in: "1.2.") == [1, 2])
        #expect(UpdateCheck.version(in: "OpenStill") == nil)
        #expect(release("OpenStill", "OpenStill v.0.1").version == [0, 1])
        #expect(release("v1.0", "Big one").versionString == "1.0")
    }
    @Test func comparisonPadsMissingParts() {
        #expect(UpdateCheck.isNewer([0, 8], than: [0, 7, 2]))
        #expect(UpdateCheck.isNewer([0, 10], than: [0, 9, 9]))
        #expect(!UpdateCheck.isNewer([1, 0], than: [1, 0, 0]))
        #expect(!UpdateCheck.isNewer([0, 7, 1], than: [0, 7, 2]))
    }
    @Test func newestSkipsDraftsOlderAndUnversionedReleases() {
        let releases = [release("OpenStill", "OpenStill v.0.1", prerelease: true), release("v0.9.0", draft: true), release("v0.8.0"), release("v0.8.3", prerelease: true), release("nightly")]
        #expect(UpdateCheck.newest(in: releases, newerThan: "0.7.2")?.tagName == "v0.8.3")
        #expect(UpdateCheck.newest(in: releases, newerThan: "0.8.3") == nil)
        #expect(UpdateCheck.newest(in: [release("OpenStill", "OpenStill v.0.1", prerelease: true)], newerThan: "0.7.2") == nil)
    }
    @Test func parsesGitHubReleaseJSON() throws {
        let json = #"[{"tag_name":"OpenStill","name":"OpenStill v.0.1","html_url":"https://github.com/haon-v2/OpenStill/releases/tag/OpenStill","draft":false,"prerelease":true,"assets":[]}]"#
        let releases = try UpdateCheck.parse(Data(json.utf8))
        #expect(releases.count == 1 && releases[0].prerelease && releases[0].title == "OpenStill v.0.1")
        #expect(throws: UpdateError.unreadable) { try UpdateCheck.parse(Data("{}".utf8)) }
    }
    @Test func sparkleNeedsFeedAndPublicKey() {
        let feed = "https://raw.githubusercontent.com/haon-v2/OpenStill/main/appcast.xml"
        let key = Data(repeating: 7, count: 32).base64EncodedString()
        #expect(UpdateCheck.sparkleConfigured(info: ["SUFeedURL": feed, "SUPublicEDKey": key]))
        #expect(!UpdateCheck.sparkleConfigured(info: ["SUFeedURL": feed]))
        #expect(!UpdateCheck.sparkleConfigured(info: ["SUFeedURL": feed, "SUPublicEDKey": ""]))
        #expect(!UpdateCheck.sparkleConfigured(info: ["SUFeedURL": feed, "SUPublicEDKey": Data(count: 16).base64EncodedString()]))
        #expect(!UpdateCheck.sparkleConfigured(info: ["SUFeedURL": "http://example.com/appcast.xml", "SUPublicEDKey": key]))
        #expect(!UpdateCheck.sparkleConfigured(info: ["SUPublicEDKey": key]))
        #expect(!UpdateCheck.sparkleConfigured(info: nil))
    }
}
