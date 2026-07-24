import XCTest
@testable import ClaudeRuntimeKit

// Item 5, §3.1 — the pure validator observes results the production child already
// produced at the post-initialize point. It validates only what is observable
// pre-turn: the initialize control response is well formed and the existing
// set_permission_mode round trip succeeded. There is NO session-id requirement —
// `session_id` is not present in the initialize response (item-2 canary), so
// requiring it would reject every certified fresh launch.
//
// These tests pin the ORDER of failure reasons and the pass path. They deliberately
// do NOT assert anything about resume or interrupt: §3.1 establishes protocol
// liveness only.

final class ClaudeBehavioralValidatorTests: XCTestCase {

	func testWellFormedInitAndRoundTripPasses() {
		let outcome = ClaudeBehavioralValidator.validate(
			initializeResponseWellFormed: true, permissionModeRoundTripSucceeded: true)
		XCTAssertEqual(outcome, .passed)
	}

	func testPermissionModeRoundTripFailureIsSpecific() {
		let outcome = ClaudeBehavioralValidator.validate(
			initializeResponseWellFormed: true, permissionModeRoundTripSucceeded: false)
		XCTAssertEqual(outcome, .failed(.permissionModeRoundTripFailed))
	}

	func testIllFormedInitTakesPrecedenceOverRoundTrip() {
		// Even with a failed round trip, the FIRST wrong thing — the ill-formed
		// initialize response — is the reason surfaced.
		let outcome = ClaudeBehavioralValidator.validate(
			initializeResponseWellFormed: false, permissionModeRoundTripSucceeded: false)
		XCTAssertEqual(outcome, .failed(.initializeNotWellFormed))
	}

	func testNoSessionIDIsRequired() {
		// A well-formed initialize response with a successful round trip passes even
		// though no session id was supplied — §3.1 does not gate on one.
		XCTAssertEqual(
			ClaudeBehavioralValidator.validate(
				initializeResponseWellFormed: true, permissionModeRoundTripSucceeded: true),
			.passed)
	}
}
