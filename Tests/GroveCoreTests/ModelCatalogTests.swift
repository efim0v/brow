import XCTest
@testable import GroveCore

/// grove#10: the pickers offer Claude Code's aliases, which never go stale, and any id.
final class ModelCatalogTests: XCTestCase {
    func testTheAliasesComeFirstAndAreClaudeCodesOwn() {
        XCTAssertEqual(ModelCatalog.aliases, ["opus", "sonnet", "haiku"])
        XCTAssertTrue(Set(ModelCatalog.aliases).isDisjoint(with: ModelCatalog.knownModels))
    }

    func testAValueTheListsDoNotKnowIsCustom() {
        XCTAssertFalse(ModelCatalog.isCustom("opus"))
        XCTAssertFalse(ModelCatalog.isCustom("claude-opus-4-8"))
        XCTAssertTrue(ModelCatalog.isCustom("claude-opus-6-0"))
    }

    func testATypedIdIsTrimmedAndMustLookLikeOne() {
        XCTAssertEqual(ModelCatalog.customID("  claude-sonnet-5  \n"), "claude-sonnet-5")
        XCTAssertEqual(ModelCatalog.customID("sonnet[1m]"), "sonnet[1m]")
        XCTAssertNil(ModelCatalog.customID("   "))
        XCTAssertNil(ModelCatalog.customID("claude opus"), "whitespace inside is not an id")
        XCTAssertNil(ModelCatalog.customID("--dangerously-skip-permissions"), "a flag is not an id")
    }

    /// Whatever the picker hands over reaches `claude` as one quoted argument.
    func testAnyIdReachesTheLaunchCommandQuoted() {
        let account = AccountConfig(name: "w", configDir: "/tmp/w-model")
        let command = ClaudeService.launchCommand(account: account, model: "sonnet[1m]")
        XCTAssertTrue(command.hasSuffix(" --model 'sonnet[1m]'"), command)
    }
}
