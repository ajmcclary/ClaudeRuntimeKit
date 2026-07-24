import XCTest
@testable import ClaudeRuntimeKit

/// Item 1 of the compatibility-admission plan. Mirrors `CodexCliVersion`, but the
/// observed Claude `--version` output is `2.1.216 (Claude Code)` — a trailing
/// parenthesised product name rather than Codex's leading `codex-cli ` prefix.
final class ClaudeCliVersionTests: XCTestCase {

	func testParsesBareTriple() {
		XCTAssertEqual(ClaudeCliVersion.parse("2.1.216"),
					   ClaudeCliVersion(major: 2, minor: 1, patch: 216))
	}

	/// The exact string emitted by `claude --version` at 2.1.216.
	func testParsesObservedVersionOutput() {
		XCTAssertEqual(ClaudeCliVersion.parse("2.1.216 (Claude Code)"),
					   ClaudeCliVersion(major: 2, minor: 1, patch: 216))
	}

	func testParsesPrerelease() {
		XCTAssertEqual(ClaudeCliVersion.parse("2.2.0-beta.1"),
					   ClaudeCliVersion(major: 2, minor: 2, patch: 0, prerelease: "beta.1"))
	}

	func testMalformedInputParsesToNil() {
		for raw in ["", "   ", "2.1", "2.1.x", "v2.1.216", "not a version",
					"2.1.216.4", "(Claude Code)"] {
			XCTAssertNil(ClaudeCliVersion.parse(raw), "expected nil for \(raw.debugDescription)")
		}
	}

	/// Only the observed `(Claude Code)` suffix is accepted. A parenthesised
	/// suffix from some other product must NOT be silently stripped — that would
	/// let a different CLI's version string parse as a Claude version.
	func testRejectsForeignParenthesisedSuffix() {
		for raw in ["2.1.216 (Other Product)", "2.1.216 (Claude)", "2.1.216 ()",
					"2.1.216 (claude code)", "2.1.216 (Claude Code) extra"] {
			XCTAssertNil(ClaudeCliVersion.parse(raw), "expected nil for \(raw.debugDescription)")
		}
	}

	// MARK: - SemVer prerelease precedence (semver.org §11)

	/// Numeric identifiers compare numerically, not lexically.
	/// Lexical ordering would wrongly place beta.10 before beta.2.
	func testNumericPrereleaseIdentifiersCompareNumerically() throws {
		let two = try XCTUnwrap(ClaudeCliVersion.parse("2.2.0-beta.2"))
		let ten = try XCTUnwrap(ClaudeCliVersion.parse("2.2.0-beta.10"))
		XCTAssertLessThan(two, ten)
		XCTAssertFalse(ten < two)
	}

	func testAlphanumericPrereleaseIdentifiersCompareLexically() throws {
		let alpha = try XCTUnwrap(ClaudeCliVersion.parse("2.2.0-alpha"))
		let beta = try XCTUnwrap(ClaudeCliVersion.parse("2.2.0-beta"))
		XCTAssertLessThan(alpha, beta)
	}

	/// A numeric identifier has lower precedence than an alphanumeric one.
	func testNumericIdentifierPrecedesAlphanumeric() throws {
		let numeric = try XCTUnwrap(ClaudeCliVersion.parse("2.2.0-1"))
		let alpha = try XCTUnwrap(ClaudeCliVersion.parse("2.2.0-alpha"))
		XCTAssertLessThan(numeric, alpha)
	}

	/// A larger set of prerelease fields has higher precedence when all
	/// preceding identifiers are equal.
	func testLongerPrereleaseFieldSetHasHigherPrecedence() throws {
		let short = try XCTUnwrap(ClaudeCliVersion.parse("2.2.0-beta.1"))
		let long = try XCTUnwrap(ClaudeCliVersion.parse("2.2.0-beta.1.1"))
		XCTAssertLessThan(short, long)
	}

	/// SemVer numeric identifiers are unbounded. Two identifiers that both
	/// overflow Int must still order by magnitude — a lexical fallback puts the
	/// 25-digit value before the 24-digit one, which is backwards.
	func testComparesNumericIdentifiersBeyondIntRange() throws {
		let smaller = try XCTUnwrap(ClaudeCliVersion.parse("2.2.0-beta.999999999999999999999999"))
		let larger = try XCTUnwrap(ClaudeCliVersion.parse("2.2.0-beta.1000000000000000000000000"))
		XCTAssertLessThan(smaller, larger)
		XCTAssertFalse(larger < smaller)
	}

	/// Equal digit counts beyond Int range fall back to lexical byte order,
	/// which is correct once both are known to be numeric of the same length.
	func testComparesEqualLengthNumericIdentifiersBeyondIntRange() throws {
		let a = try XCTUnwrap(ClaudeCliVersion.parse("2.2.0-1000000000000000000000001"))
		let b = try XCTUnwrap(ClaudeCliVersion.parse("2.2.0-1000000000000000000000002"))
		XCTAssertLessThan(a, b)
	}

	// MARK: - SemVer identifier validity

	func testRejectsEmptyPrereleaseIdentifiers() {
		for raw in ["2.2.0-", "2.2.0-.beta", "2.2.0-beta.", "2.2.0-beta..1"] {
			XCTAssertNil(ClaudeCliVersion.parse(raw), "expected nil for \(raw.debugDescription)")
		}
	}

	func testRejectsLeadingZeroNumericPrereleaseIdentifiers() {
		for raw in ["2.2.0-01", "2.2.0-beta.01", "2.2.0-00"] {
			XCTAssertNil(ClaudeCliVersion.parse(raw), "expected nil for \(raw.debugDescription)")
		}
	}

	/// `0` alone is a legal numeric identifier; only *leading* zeroes are illegal.
	func testAcceptsZeroNumericPrereleaseIdentifier() throws {
		XCTAssertEqual(ClaudeCliVersion.parse("2.2.0-0"),
					   ClaudeCliVersion(major: 2, minor: 2, patch: 0, prerelease: "0"))
		XCTAssertEqual(ClaudeCliVersion.parse("2.2.0-beta.0"),
					   ClaudeCliVersion(major: 2, minor: 2, patch: 0, prerelease: "beta.0"))
	}

	func testRejectsLeadingZeroCoreFields() {
		for raw in ["02.1.216", "2.01.216", "2.1.0216"] {
			XCTAssertNil(ClaudeCliVersion.parse(raw), "expected nil for \(raw.debugDescription)")
		}
	}

	func testAcceptsZeroCoreFields() {
		XCTAssertEqual(ClaudeCliVersion.parse("0.1.0"),
					   ClaudeCliVersion(major: 0, minor: 1, patch: 0))
	}

	/// Hyphens are legal inside an alphanumeric prerelease identifier.
	func testAcceptsHyphenatedPrereleaseIdentifier() throws {
		XCTAssertEqual(ClaudeCliVersion.parse("2.2.0-beta-1"),
					   ClaudeCliVersion(major: 2, minor: 2, patch: 0, prerelease: "beta-1"))
	}

	func testEqualPrereleasesAreNotOrdered() throws {
		let a = try XCTUnwrap(ClaudeCliVersion.parse("2.2.0-beta.1"))
		let b = try XCTUnwrap(ClaudeCliVersion.parse("2.2.0-beta.1"))
		XCTAssertFalse(a < b)
		XCTAssertFalse(b < a)
	}

	func testOrdersByPatch() throws {
		let a = try XCTUnwrap(ClaudeCliVersion.parse("2.1.215"))
		let b = try XCTUnwrap(ClaudeCliVersion.parse("2.1.216"))
		XCTAssertLessThan(a, b)
	}

	func testPrereleasePrecedesItsRelease() throws {
		let pre = try XCTUnwrap(ClaudeCliVersion(major: 2, minor: 2, patch: 0, prerelease: "beta.1"))
		let rel = try XCTUnwrap(ClaudeCliVersion(major: 2, minor: 2, patch: 0))
		XCTAssertLessThan(pre, rel)
	}

	// MARK: - Construction invariants
	//
	// `parse` is not the only construction path. The public initializer must
	// enforce the same invariants, or a caller can hand `comparePrerelease` a
	// value it will misorder — e.g. prerelease "01", whose digit count differs
	// from "1" while its magnitude does not.

	func testDirectConstructionRejectsInvalidPrerelease() {
		for prerelease in ["01", "", "beta..1", "beta.", ".beta", "00", "beta.01",
						   "beta+meta", "béta"] {
			XCTAssertNil(ClaudeCliVersion(major: 2, minor: 2, patch: 0, prerelease: prerelease),
						 "expected nil for prerelease \(prerelease.debugDescription)")
		}
	}

	func testDirectConstructionRejectsNegativeCoreFields() {
		XCTAssertNil(ClaudeCliVersion(major: -1, minor: 0, patch: 0))
		XCTAssertNil(ClaudeCliVersion(major: 0, minor: -1, patch: 0))
		XCTAssertNil(ClaudeCliVersion(major: 0, minor: 0, patch: -1))
	}

	func testDirectConstructionAcceptsValidValues() {
		XCTAssertNotNil(ClaudeCliVersion(major: 2, minor: 1, patch: 216))
		XCTAssertNotNil(ClaudeCliVersion(major: 2, minor: 2, patch: 0, prerelease: "beta.1"))
		XCTAssertNotNil(ClaudeCliVersion(major: 0, minor: 0, patch: 0, prerelease: "0"))
		XCTAssertNotNil(ClaudeCliVersion(major: 2, minor: 2, patch: 0, prerelease: "beta-1"))
	}

	func testDescriptionRoundTrips() {
		XCTAssertEqual(ClaudeCliVersion.parse("2.1.216")?.description, "2.1.216")
		XCTAssertEqual(ClaudeCliVersion.parse("2.2.0-beta.1")?.description, "2.2.0-beta.1")
	}
}
