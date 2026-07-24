import XCTest
@testable import ClaudeRuntimeKit

/// Program A Slice 4b, step 2 — normalized lifecycle vocabulary.
///
/// These are DESIRED-BEHAVIOR tests, not characterization.
///
/// The contract being pinned: a lifecycle event describes WHAT ARRIVED on the
/// wire — its wire identity and its scope — and nothing else. It carries no app
/// turn ID and no completion authority. The decoder describes; it does not
/// decide.
final class ClaudeLifecycleEventTests: XCTestCase {

	// MARK: - Run-state classification

	func testRunningAndIdleStatesAreClassified() {
		let running = ClaudeLifecycleNormalizer.lifecycleEvent(
			payloadType: "system",
			subtype: "session_state_changed",
			sessionState: "running",
			identity: .empty
		)
		XCTAssertEqual(running?.phase, .runStateChanged(.running), "a running session state is a run-state transition")

		let idle = ClaudeLifecycleNormalizer.lifecycleEvent(
			payloadType: "system",
			subtype: "session_state_changed",
			sessionState: "idle",
			identity: .empty
		)
		XCTAssertEqual(idle?.phase, .runStateChanged(.idle), "an idle session state is a run-state transition")
	}

	/// An unrecognized run state is preserved verbatim rather than collapsed into
	/// idle or dropped. Guessing here would invent a completion boundary.
	func testUnrecognizedRunStateIsPreservedNotGuessed() {
		let event = ClaudeLifecycleNormalizer.lifecycleEvent(
			payloadType: "system",
			subtype: "session_state_changed",
			sessionState: "compacting",
			identity: .empty
		)
		XCTAssertEqual(
			event?.phase,
			.runStateChanged(.other("compacting")),
			"an unknown state must survive as itself, never be coerced to a known one"
		)
	}

	func testRunStateIsNormalizedForCaseAndSurroundingWhitespace() {
		let event = ClaudeLifecycleNormalizer.lifecycleEvent(
			payloadType: "system",
			subtype: "session_state_changed",
			sessionState: "  IDLE  ",
			identity: .empty
		)
		XCTAssertEqual(event?.phase, .runStateChanged(.idle), "state matching is case- and whitespace-insensitive")
	}

	func testSessionStateChangedWithoutAStateIsNotALifecycleEvent() {
		let missing = ClaudeLifecycleNormalizer.lifecycleEvent(
			payloadType: "system",
			subtype: "session_state_changed",
			sessionState: nil,
			identity: .empty
		)
		XCTAssertNil(missing, "a state change with no state carries no lifecycle fact")

		let blank = ClaudeLifecycleNormalizer.lifecycleEvent(
			payloadType: "system",
			subtype: "session_state_changed",
			sessionState: "   ",
			identity: .empty
		)
		XCTAssertNil(blank, "a blank state carries no lifecycle fact")
	}

	// MARK: - Result observation

	func testResultFrameIsObservedAtTopLevelScope() {
		let event = ClaudeLifecycleNormalizer.lifecycleEvent(
			payloadType: "result",
			subtype: "success",
			sessionState: nil,
			identity: ClaudeLifecycleIdentity(sessionID: "s-1", messageID: "m-1", taskID: nil)
		)
		XCTAssertEqual(event?.phase, .resultObserved, "a result frame is an observation of a result")
		XCTAssertEqual(event?.scope, .topLevel, "a result with no task id belongs to the top-level conversation")
		XCTAssertEqual(event?.identity.sessionID, "s-1")
		XCTAssertEqual(event?.identity.messageID, "m-1")
	}

	/// A result frame carrying a task id is genuinely ambiguous: it could be a
	/// child result or a top-level result annotated with the task that produced
	/// it. `.unresolved` records the ambiguity instead of guessing — and because
	/// the reconciler never completes on an unresolved scope, guessing wrong here
	/// would be exactly the "child event completes a top-level turn" bug.
	func testResultCarryingATaskIDHasUnresolvedScope() {
		let event = ClaudeLifecycleNormalizer.lifecycleEvent(
			payloadType: "result",
			subtype: "success",
			sessionState: nil,
			identity: ClaudeLifecycleIdentity(sessionID: "s-1", messageID: "m-1", taskID: "child-7")
		)
		XCTAssertEqual(event?.phase, .resultObserved)
		XCTAssertEqual(
			event?.scope,
			.unresolved,
			"an ambiguous result must be unresolved, never silently attributed to the top level"
		)
	}

	// MARK: - Child / subagent events

	func testChildTaskEventsCarryChildScope() {
		let identity = ClaudeLifecycleIdentity(sessionID: "s-1", messageID: nil, taskID: "child-1")
		let cases: [(String, ClaudeLifecycleEvent.Phase)] = [
			("task_started", .childTaskStarted),
			("task_notification", .childTaskNotification),
			("task_progress", .childTaskProgress)
		]
		for (subtype, expected) in cases {
			let event = ClaudeLifecycleNormalizer.lifecycleEvent(
				payloadType: "system",
				subtype: subtype,
				sessionState: nil,
				identity: identity
			)
			XCTAssertEqual(event?.phase, expected, "\(subtype) must map to its own phase")
			XCTAssertEqual(event?.scope, .child, "\(subtype) is child scope")
			XCTAssertEqual(event?.identity.taskID, "child-1", "\(subtype) keeps its wire task id")
		}
	}

	/// A child event with no task id is still child-scoped by its subtype — the
	/// missing identity does not promote it to the top level.
	func testChildEventWithoutATaskIDStaysChildScoped() {
		let event = ClaudeLifecycleNormalizer.lifecycleEvent(
			payloadType: "system",
			subtype: "task_started",
			sessionState: nil,
			identity: .empty
		)
		XCTAssertEqual(event?.scope, .child, "a missing task id must never promote a child event to top level")
		XCTAssertNil(event?.identity.taskID)
	}

	// MARK: - Non-lifecycle input

	func testNonLifecycleFramesProduceNoEvent() {
		XCTAssertNil(
			ClaudeLifecycleNormalizer.lifecycleEvent(
				payloadType: "assistant",
				subtype: nil,
				sessionState: nil,
				identity: .empty
			),
			"an assistant message is not a lifecycle event"
		)
		XCTAssertNil(
			ClaudeLifecycleNormalizer.lifecycleEvent(
				payloadType: "system",
				subtype: "compact_boundary",
				sessionState: nil,
				identity: .empty
			),
			"an unrelated system subtype is not a lifecycle event"
		)
	}

	// MARK: - Structural constraints

	/// The vocabulary must not be able to name an app turn. If a `turnID` ever
	/// appears here, the decoder has acquired completion authority.
	func testLifecycleEventCarriesOnlyPhaseIdentityAndScope() {
		let event = ClaudeLifecycleEvent(phase: .resultObserved, identity: .empty, scope: .topLevel)
		let fields = Set(Mirror(reflecting: event).children.compactMap(\.label))
		XCTAssertEqual(
			fields,
			["phase", "identity", "scope"],
			"a lifecycle event describes what arrived and nothing more; got \(fields)"
		)
	}

	func testLifecycleIdentityCarriesOnlyWireIdentifiers() {
		let identity = ClaudeLifecycleIdentity(sessionID: "s", messageID: "m", taskID: "t")
		let fields = Set(Mirror(reflecting: identity).children.compactMap(\.label))
		XCTAssertEqual(
			fields,
			["sessionID", "messageID", "taskID"],
			"identity is WIRE identity only — no app turn id may appear here; got \(fields)"
		)
	}

	func testEmptyIdentityHasNoIdentifiers() {
		XCTAssertNil(ClaudeLifecycleIdentity.empty.sessionID)
		XCTAssertNil(ClaudeLifecycleIdentity.empty.messageID)
		XCTAssertNil(ClaudeLifecycleIdentity.empty.taskID)
	}
}
