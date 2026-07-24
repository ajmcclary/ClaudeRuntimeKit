import XCTest
@testable import ClaudeRuntimeKit

/// Item 1 of the compatibility-admission plan. Pure values only — no filesystem,
/// no process, no `CommandPathResolver`. The app-side resolver owns all IO and
/// maps its launchability outcomes into these bounded cases.
final class ClaudeRuntimeIdentityTests: XCTestCase {

	private let validHex = String(repeating: "ab12cd34", count: 8)   // 64 chars

	// MARK: - ClaudeSHA256

	func testAcceptsExactly64LowercaseHexCharacters() throws {
		let hash = try XCTUnwrap(ClaudeSHA256(validHex))
		XCTAssertEqual(hash.value, validHex)
		XCTAssertEqual(hash.description, validHex)
	}

	/// Uppercase is rejected rather than normalised: the resolver must lowercase
	/// deliberately, so a mixed-case hash can never reach a cache key.
	func testRejectsUppercaseHex() {
		XCTAssertNil(ClaudeSHA256(String(repeating: "AB12CD34", count: 8)))
		XCTAssertNil(ClaudeSHA256(String(repeating: "Ab12cd34", count: 8)))
	}

	func testRejectsWrongLength() {
		XCTAssertNil(ClaudeSHA256(""))
		XCTAssertNil(ClaudeSHA256(String(repeating: "a", count: 63)))
		XCTAssertNil(ClaudeSHA256(String(repeating: "a", count: 65)))
	}

	func testRejectsNonHexCharacters() {
		XCTAssertNil(ClaudeSHA256(String(repeating: "g", count: 64)))
		XCTAssertNil(ClaudeSHA256(String(repeating: "a", count: 63) + " "))
		XCTAssertNil(ClaudeSHA256(String(repeating: "a", count: 63) + "-"))
	}

	func testIsHashableByValue() throws {
		let a = try XCTUnwrap(ClaudeSHA256(validHex))
		let b = try XCTUnwrap(ClaudeSHA256(validHex))
		XCTAssertEqual(a, b)
		XCTAssertEqual(Set([a, b]).count, 1)
	}

	// MARK: - ClaudeRuntimeIdentity

	private func makeIdentity(
		resolvedPath: String = "/opt/homebrew/bin/claude",
		realPath: String = "/opt/homebrew/Cellar/claude/2.1.216/bin/claude",
		sizeBytes: Int = 249_225_584,
		signingClass: ClaudeExecutableSigningClass = .appleDeveloperID,
		pathClass: ClaudeExecutablePathClass = .homebrew
	) -> ClaudeRuntimeIdentity? {
		ClaudeRuntimeIdentity(
			resolvedPath: resolvedPath,
			realPath: realPath,
			sha256: ClaudeSHA256(validHex)!,
			sizeBytes: sizeBytes,
			signingClass: signingClass,
			pathClass: pathClass
		)
	}

	func testConstructsWithValidComponents() throws {
		let identity = try XCTUnwrap(makeIdentity())
		XCTAssertEqual(identity.resolvedPath, "/opt/homebrew/bin/claude")
		XCTAssertEqual(identity.sha256.value, validHex)
		XCTAssertEqual(identity.pathClass, .homebrew)
	}

	func testRejectsEmptyPaths() {
		XCTAssertNil(makeIdentity(resolvedPath: ""))
		XCTAssertNil(makeIdentity(realPath: ""))
		XCTAssertNil(makeIdentity(resolvedPath: "   "))
	}

	func testRejectsNegativeSize() {
		XCTAssertNil(makeIdentity(sizeBytes: -1))
	}

	/// A zero-byte file is not a plausible executable, but it is a real
	/// filesystem state; the resolver decides, not the value type.
	func testAcceptsZeroSize() {
		XCTAssertNotNil(makeIdentity(sizeBytes: 0))
	}

	// MARK: - ClaudeRuntimeResolution

	/// Codesign failure is NOT an identification failure: the bytes are still
	/// identified and hashed, so resolution succeeds with `.unreadable`.
	func testSigningFailureStillResolves() throws {
		let identity = try XCTUnwrap(makeIdentity(signingClass: .unreadable))
		let resolution = ClaudeRuntimeResolution.resolved(identity)
		guard case .resolved(let resolved) = resolution else {
			return XCTFail("expected .resolved")
		}
		XCTAssertEqual(resolved.signingClass, .unreadable)
	}

	func testUnresolvableCarriesBoundedReason() {
		let resolution = ClaudeRuntimeResolution.unresolvable(.noPath)
		guard case .unresolvable(let reason) = resolution else {
			return XCTFail("expected .unresolvable")
		}
		XCTAssertEqual(reason, .noPath)
	}

	/// Pins the bounded case sets. Adding a case must be a deliberate edit here,
	/// not an incidental widening of the admission vocabulary.
	func testBoundedVocabulariesArePinned() {
		XCTAssertEqual(
			Set(ClaudeRuntimeUnresolvableReason.allCases.map(\.rawValue)),
			["noPath", "missingPath", "notExecutable", "isDirectory", "hashUnreadable",
			 "canonicalPathUnreadable"]
		)
		XCTAssertEqual(
			Set(ClaudeExecutableSigningClass.allCases.map(\.rawValue)),
			["appleDeveloperID", "applePlatform", "otherSigned", "adHoc",
			 "unsigned", "invalid", "unreadable"]
		)
		XCTAssertEqual(
			Set(ClaudeExecutablePathClass.allCases.map(\.rawValue)),
			["homebrew", "npmGlobal", "userLocal", "system", "unknown"]
		)
	}
}
