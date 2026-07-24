import XCTest
@testable import ClaudeRuntimeKit

/// Program A Slice 4b, step 5 — parity comparator.
///
/// DESIRED-BEHAVIOR tests.
///
/// The comparator's job is to be UNABLE to miss a difference. The Slice 2/3
/// parity gate reported parity while a whole usage model was absent, because
/// its comparable form omitted the fields that would have shown it. These tests
/// pin that every field of a completion participates — especially the trigger,
/// which is the one the earlier design of this comparator could not see.
final class ClaudeLifecycleParityTests: XCTestCase {

	private let turnA = ClaudeTurnGeneration(value: 1)
	private let turnB = ClaudeTurnGeneration(value: 2)

	private func completion(
		_ turn: ClaudeTurnGeneration,
		_ outcome: ClaudeTurnOutcome = .completed,
		_ trigger: ClaudeCompletionTrigger = .idleBoundary
	) -> ClaudeReconciledCompletion {
		ClaudeReconciledCompletion(turn: turn, outcome: outcome, trigger: trigger)
	}

	// MARK: - Parity

	func testIdenticalLanesReportNoMismatches() {
		let lane = [completion(turnA), completion(turnB, .failed, .fallbackTimer)]
		XCTAssertEqual(
			ClaudeLifecycleParity.compare(legacy: lane, normalized: lane),
			[],
			"identical lanes must produce no mismatches"
		)
	}

	func testEmptyLanesReportNoMismatches() {
		XCTAssertEqual(ClaudeLifecycleParity.compare(legacy: [], normalized: []), [])
	}

	// MARK: - Every field is compared

	/// The blindness guard. Same turn, same outcome, different mechanism — a
	/// comparator keyed only on (turn, outcome) calls this parity, which is
	/// exactly how the early-idle defect would hide.
	func testATriggerDifferenceAloneIsReported() {
		let mismatches = ClaudeLifecycleParity.compare(
			legacy: [completion(turnA, .completed, .fallbackTimer)],
			normalized: [completion(turnA, .completed, .rememberedIdleAtResult)]
		)
		XCTAssertEqual(
			mismatches,
			[.triggerDiffers(turn: turnA, legacy: .fallbackTimer, normalized: .rememberedIdleAtResult)],
			"a mechanism difference is a real divergence and must not be absorbed"
		)
	}

	func testAnOutcomeDifferenceIsReported() {
		let mismatches = ClaudeLifecycleParity.compare(
			legacy: [completion(turnA, .cancelled)],
			normalized: [completion(turnA, .completed)]
		)
		XCTAssertEqual(
			mismatches,
			[.outcomeDiffers(turn: turnA, legacy: .cancelled, normalized: .completed)]
		)
	}

	func testACompletionPresentInOnlyOneLaneIsReported() {
		XCTAssertEqual(
			ClaudeLifecycleParity.compare(legacy: [completion(turnA)], normalized: []),
			[.completedOnlyInLegacy(completion(turnA))],
			"a turn legacy completed and the reconciler did not must surface"
		)
		XCTAssertEqual(
			ClaudeLifecycleParity.compare(legacy: [], normalized: [completion(turnA)]),
			[.completedOnlyInNormalized(completion(turnA))],
			"a turn the reconciler completed and legacy did not must surface — this is defect 4's shape"
		)
	}

	func testAnOrderDifferenceIsReported() {
		let mismatches = ClaudeLifecycleParity.compare(
			legacy: [completion(turnA), completion(turnB)],
			normalized: [completion(turnB), completion(turnA)]
		)
		XCTAssertEqual(
			mismatches,
			[
				.orderDiffers(turn: turnA, legacyIndex: 0, normalizedIndex: 1),
				.orderDiffers(turn: turnB, legacyIndex: 1, normalizedIndex: 0)
			],
			"completion order is observable behavior and is compared"
		)
	}

	/// Differences compound rather than masking one another.
	func testMultipleFieldDifferencesOnOneTurnAreAllReported() {
		let mismatches = ClaudeLifecycleParity.compare(
			legacy: [completion(turnA, .cancelled, .fallbackTimer)],
			normalized: [completion(turnA, .completed, .idleBoundary)]
		)
		XCTAssertEqual(
			mismatches,
			[
				.outcomeDiffers(turn: turnA, legacy: .cancelled, normalized: .completed),
				.triggerDiffers(turn: turnA, legacy: .fallbackTimer, normalized: .idleBoundary)
			],
			"one field's difference must not short-circuit the rest"
		)
	}

	// MARK: - Structural guards

	/// If a field is added to a completion without being added to the
	/// comparison, the comparator goes blind in exactly the Slice 2/3 way. This
	/// pins the field set so that widening it is a deliberate act.
	func testComparableCompletionCarriesEveryFieldTheComparisonKnowsAbout() {
		let fields = Set(
			Mirror(reflecting: completion(turnA)).children.compactMap(\.label)
		)
		XCTAssertEqual(
			fields,
			["turn", "outcome", "trigger"],
			"adding a field here without adding it to compare() reintroduces structural blindness; got \(fields)"
		)
	}

	/// The divergence allowlist is exactly four named defects — never a
	/// category, and never open-ended.
	/// RENAMED AT F3. Was: the list is exactly the four named defects.
	///
	/// All four were resolved by the production flip, so the correct content is
	/// now none. Asserting emptiness by name means re-accepting a divergence has to
	/// break a test that says so, instead of quietly appending a case.
	func testTheExpectedDivergenceListIsEmptyBecauseAllFourWereResolved() {
		XCTAssertTrue(
			ClaudeExpectedLifecycleDivergence.allCases.isEmpty,
			"no divergence is accepted between the two projection modes: they run "
			+ "under ONE lifecycle authority. Adding a case here means re-accepting "
			+ "a defect, which must be a deliberate, reviewed act"
		)
	}

	func testEveryCompletionTriggerIsDistinguishable() {
		let raw = ClaudeCompletionTrigger.allCases.map(\.rawValue)
		XCTAssertEqual(
			Set(raw).count,
			raw.count,
			"two triggers sharing a raw value would collapse a real divergence into parity"
		)
	}
}
