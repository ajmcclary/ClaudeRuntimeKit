import XCTest
@testable import ClaudeRuntimeKit

// Item 6 — the §7.1 precedence resolver and the stage parser, both pure.
//
// Finding 5: an override read is a TRI-STATE — `.absent`, `.valid(stage)`, or
// `.malformed`. Absence follows precedence (yield to the next layer); a malformed
// value at a layer resolves fail-safe to `.observeOnly` IMMEDIATELY and does NOT
// fall through. Distinguishing malformed from absent is load-bearing: today the
// build constant is `.observeOnly`, but after a future promotion an absent-style
// fall-through would let a malformed override inherit `.enforceKnownBad`/
// `.enforceAll`. It must never raise enforcement.

final class ClaudeAdmissionEnforcementTests: XCTestCase {

	// MARK: - Precedence (§7.1)

	func testDebugValidOverrideWinsOverEverything() {
		let stage = ClaudeAdmissionEnforcementResolution.resolve(
			debug: .valid(.enforceAll), managed: .valid(.enforceKnownBad),
			buildTimeShipping: .observeOnly)
		XCTAssertEqual(stage, .enforceAll)
	}

	func testManagedValidUsedWhenDebugAbsent() {
		let stage = ClaudeAdmissionEnforcementResolution.resolve(
			debug: .absent, managed: .valid(.enforceLimited), buildTimeShipping: .observeOnly)
		XCTAssertEqual(stage, .enforceLimited)
	}

	func testBuildTimeUsedWhenBothAbsent() {
		let stage = ClaudeAdmissionEnforcementResolution.resolve(
			debug: .absent, managed: .absent, buildTimeShipping: .enforceKnownBad)
		XCTAssertEqual(stage, .enforceKnownBad)
	}

	func testAbsentManagedFallsThroughToRaisedBuildTime() {
		// Absence follows precedence: an unset managed key inherits the build-time
		// stage, even a raised one.
		let stage = ClaudeAdmissionEnforcementResolution.resolve(
			debug: .absent, managed: .absent, buildTimeShipping: .enforceAll)
		XCTAssertEqual(stage, .enforceAll)
	}

	func testMalformedManagedFailsSafeEvenWithRaisedBuildTime() {
		// THE regression guard: a malformed managed value must resolve to observeOnly,
		// NOT fall through to a raised build-time stage.
		let stage = ClaudeAdmissionEnforcementResolution.resolve(
			debug: .absent, managed: .malformed, buildTimeShipping: .enforceAll)
		XCTAssertEqual(stage, .observeOnly)
	}

	func testMalformedDebugFailsSafeAndDoesNotConsultManaged() {
		// A malformed higher-precedence override fails safe immediately; it does not
		// fall through to a valid lower-precedence override.
		let stage = ClaudeAdmissionEnforcementResolution.resolve(
			debug: .malformed, managed: .valid(.enforceAll), buildTimeShipping: .enforceAll)
		XCTAssertEqual(stage, .observeOnly)
	}

	func testAllAbsentWithObserveOnlyBuildTimeIsObserveOnly() {
		let stage = ClaudeAdmissionEnforcementResolution.resolve(
			debug: .absent, managed: .absent, buildTimeShipping: .observeOnly)
		XCTAssertEqual(stage, .observeOnly)
	}

	// MARK: - Stage parsing

	func testStageParsesCaseNames() {
		XCTAssertEqual(ClaudeAdmissionEnforcementStage(overrideValue: "observeOnly"), .observeOnly)
		XCTAssertEqual(ClaudeAdmissionEnforcementStage(overrideValue: "enforceKnownBad"), .enforceKnownBad)
		XCTAssertEqual(ClaudeAdmissionEnforcementStage(overrideValue: "enforceLimited"), .enforceLimited)
		XCTAssertEqual(ClaudeAdmissionEnforcementStage(overrideValue: "enforceAll"), .enforceAll)
	}

	func testStageParsesIntegerRawValues() {
		XCTAssertEqual(ClaudeAdmissionEnforcementStage(overrideValue: " 0 "), .observeOnly)
		XCTAssertEqual(ClaudeAdmissionEnforcementStage(overrideValue: "3"), .enforceAll)
	}

	func testStageRejectsOutOfRangeInteger() {
		XCTAssertNil(ClaudeAdmissionEnforcementStage(overrideValue: "4"))
		XCTAssertNil(ClaudeAdmissionEnforcementStage(overrideValue: "-1"))
	}

	func testStageRejectsGarbage() {
		XCTAssertNil(ClaudeAdmissionEnforcementStage(overrideValue: "true"))
		XCTAssertNil(ClaudeAdmissionEnforcementStage(overrideValue: "ENFORCEALL"))
	}

	func testStageIsOrdered() {
		XCTAssertLessThan(ClaudeAdmissionEnforcementStage.observeOnly, .enforceKnownBad)
		XCTAssertLessThan(ClaudeAdmissionEnforcementStage.enforceKnownBad, .enforceLimited)
		XCTAssertLessThan(ClaudeAdmissionEnforcementStage.enforceLimited, .enforceAll)
	}
}
