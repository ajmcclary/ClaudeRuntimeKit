import XCTest
@testable import ClaudeRuntimeKit

/// Program A Slice 4b, step 4 — pure lifecycle reconciler.
///
/// DESIRED-BEHAVIOR tests.
///
/// The reconciler turns stamped lifecycle inputs into explicit decisions:
/// observe · defer · complete · ignoreReplay · quarantine. It holds no app
/// types and performs no IO — completion AUTHORITY stays with the controller,
/// which during Slice 4b consumes none of these decisions.
///
/// Where a decision differs from the behavior pinned by step-1
/// characterization, the test names the defect it corrects. Those differences
/// are the step-5 divergence list; they are NOT applied to production here.
final class ClaudeLifecycleReconcilerTests: XCTestCase {

	// MARK: - Helpers

	private func stamp(
		_ input: ClaudeLifecycleInput,
		epoch: ClaudeTransportEpoch = .initial
	) -> ClaudeStampedLifecycleInput {
		ClaudeStampedLifecycleInput(epoch: epoch, input: input)
	}

	private func result(
		sessionID: String? = nil,
		taskID: String? = nil,
		scope: ClaudeLifecycleScope = .topLevel
	) -> ClaudeLifecycleInput {
		.wire(
			ClaudeLifecycleEvent(
				phase: .resultObserved,
				identity: ClaudeLifecycleIdentity(sessionID: sessionID, messageID: nil, taskID: taskID),
				scope: scope
			)
		)
	}

	private func runState(_ state: ClaudeLifecycleRunState) -> ClaudeLifecycleInput {
		.wire(
			ClaudeLifecycleEvent(
				phase: .runStateChanged(state),
				identity: .empty,
				scope: .topLevel
			)
		)
	}

	private let turnA = ClaudeTurnGeneration(value: 1)
	private let turnB = ClaudeTurnGeneration(value: 2)

	// MARK: - The ordinary path

	func testResultThenIdleDefersThenCompletes() {
		var reconciler = ClaudeLifecycleReconciler()
		reconciler.openTurn(turnA)
		// The provider must have demonstrated it marks boundaries before a result
		// will wait for one. Established per test rather than in a shared helper:
		// hiding it in setup would erase coverage of the real 2.1.215 path, where
		// no boundary is ever signalled.
		_ = reconciler.reconcile(stamp(runState(.running)))

		let atResult = reconciler.reconcile(stamp(result()), observedOutcome: .completed)
		XCTAssertEqual(atResult, [.defer(turn: turnA)], "a result with no idle yet defers")

		let atIdle = reconciler.reconcile(stamp(runState(.idle)))
		XCTAssertEqual(
			atIdle,
			[.complete(turn: turnA, outcome: .completed, trigger: .idleBoundary)],
			"idle completes the deferred turn with the status observed at result time"
		)
	}

	func testChildEventsOnlyEverObserve() {
		var reconciler = ClaudeLifecycleReconciler()
		reconciler.openTurn(turnA)

		for phase in [
			ClaudeLifecycleEvent.Phase.childTaskStarted,
			.childTaskNotification,
			.childTaskProgress
		] {
			let event = ClaudeLifecycleEvent(
				phase: phase,
				identity: ClaudeLifecycleIdentity(sessionID: nil, messageID: nil, taskID: "child-1"),
				scope: .child
			)
			XCTAssertEqual(
				reconciler.reconcile(stamp(.wire(event))),
				[.observe],
				"\(phase) must never complete a top-level turn"
			)
		}
	}

	/// `.unresolved` is the conservative classification for a result carrying a
	/// task id. It must not complete a turn without later corroboration.
	func testUnresolvedScopeResultNeverCompletesOrDefers() {
		var reconciler = ClaudeLifecycleReconciler()
		reconciler.openTurn(turnA)

		let decisions = reconciler.reconcile(
			stamp(result(taskID: "child-7", scope: .unresolved)),
			observedOutcome: .completed
		)
		XCTAssertEqual(decisions, [.observe], "an ambiguous result resolves nothing")

		// The turn is still open, so a subsequent unambiguous result still works.
		// It completes rather than defers because no boundary capability was ever
		// demonstrated — deferral was incidental to what this test guards, which is
		// that the ambiguous event left the turn available.
		XCTAssertEqual(
			reconciler.reconcile(stamp(result()), observedOutcome: .completed),
			[.complete(turn: turnA, outcome: .completed, trigger: .resultWithoutIdleBoundary)],
			"the ambiguous result must not have consumed the open turn"
		)
	}

	// MARK: - Idle-boundary capability

	/// The ORDINARY production path on real 2.1.215, which never emits
	/// `session_state_changed`. If this deferred instead, every turn would wait out
	/// `authoritativeTurnIdleFallbackSeconds` before completing.
	func testResultCompletesImmediatelyUntilTheProviderProvesItMarksBoundaries() {
		var reconciler = ClaudeLifecycleReconciler()
		reconciler.openTurn(turnA)

		XCTAssertEqual(
			reconciler.reconcile(stamp(result()), observedOutcome: .completed),
			[.complete(turn: turnA, outcome: .completed, trigger: .resultWithoutIdleBoundary)],
			"with no boundary capability demonstrated, the result IS the boundary"
		)
	}

	/// Capability is a property of the transport, learned once and kept. A
	/// non-idle state establishes it just as well as an idle one — what matters is
	/// that the provider marks run state at all.
	func testANonIdleRunStateUpgradesTheTransportToDeferredCompletion() {
		var reconciler = ClaudeLifecycleReconciler()
		reconciler.openTurn(turnA)
		XCTAssertEqual(
			reconciler.reconcile(stamp(runState(.running))),
			[.observe],
			"a running state completes nothing by itself"
		)

		XCTAssertEqual(
			reconciler.reconcile(stamp(result()), observedOutcome: .completed),
			[.defer(turn: turnA)],
			"once the provider has marked run state, a result waits for its boundary"
		)
	}

	func testCapabilityIsResetWhenTheTransportIsReplaced() {
		var reconciler = ClaudeLifecycleReconciler()
		// No turn is opened on the old transport: capability is established by the
		// run-state frame alone, and leaving a turn open here would only let the
		// later result match IT rather than testing capability.
		_ = reconciler.reconcile(stamp(runState(.running)))

		let newEpoch = ClaudeTransportEpoch.initial.next()
		_ = reconciler.reconcile(stamp(.host(.transportReestablished), epoch: newEpoch))

		reconciler.openTurn(turnB)
		XCTAssertEqual(
			reconciler.reconcile(stamp(result(), epoch: newEpoch), observedOutcome: .completed),
			[.complete(turn: turnB, outcome: .completed, trigger: .resultWithoutIdleBoundary)],
			"a capability demonstrated by a dead transport says nothing about its replacement"
		)
	}

	/// Capability must come from real, current, top-level run state — not from a
	/// child task's state, and not from a frame belonging to a dead transport.
	func testChildAndReplayedRunStatesDoNotEstablishCapability() {
		var reconciler = ClaudeLifecycleReconciler()

		let childRunState = ClaudeLifecycleEvent(
			phase: .runStateChanged(.running),
			identity: ClaudeLifecycleIdentity(sessionID: nil, messageID: nil, taskID: "child-1"),
			scope: .child
		)
		_ = reconciler.reconcile(stamp(.wire(childRunState)))

		let newEpoch = ClaudeTransportEpoch.initial.next()
		_ = reconciler.reconcile(stamp(.host(.transportReestablished), epoch: newEpoch))
		reconciler.openTurn(turnB)
		// Stamped against the dead transport: ignored before it can teach anything.
		_ = reconciler.reconcile(stamp(runState(.running), epoch: .initial))

		XCTAssertEqual(
			reconciler.reconcile(stamp(result(), epoch: newEpoch), observedOutcome: .completed),
			[.complete(turn: turnB, outcome: .completed, trigger: .resultWithoutIdleBoundary)],
			"neither a child run state nor a replayed one may establish capability"
		)
	}

	// MARK: - FIFO boundary matching

	/// An idle frame carries no turn identity, so FIFO is the only deterministic
	/// rule available for choosing WHICH deferred record it closes. That is
	/// permitted in the core precisely because the selected record already carries
	/// its own generation — the boundary selects a record, it never retargets one.
	func testTwoDeferredTurnsCompleteInFIFOOrderUnderTwoBoundaries() {
		var reconciler = ClaudeLifecycleReconciler()
		reconciler.openTurn(turnA)
		reconciler.openTurn(turnB)
		_ = reconciler.reconcile(stamp(runState(.running)))

		XCTAssertEqual(
			reconciler.reconcile(stamp(result()), observedOutcome: .completed),
			[.defer(turn: turnA)]
		)
		XCTAssertEqual(
			reconciler.reconcile(stamp(result()), observedOutcome: .failed),
			[.defer(turn: turnB)]
		)

		XCTAssertEqual(
			reconciler.reconcile(stamp(runState(.idle))),
			[.complete(turn: turnA, outcome: .completed, trigger: .idleBoundary)],
			"the first boundary closes the oldest deferred record"
		)
		XCTAssertEqual(
			reconciler.reconcile(stamp(runState(.idle))),
			[.complete(turn: turnB, outcome: .failed, trigger: .idleBoundary)],
			"each outcome stays attached to the generation it was observed for"
		)
	}

	/// Separates "which record the boundary selects" from "what outcome that record
	/// carries". A regression that reintroduced a controller-wide interrupt flag by
	/// another name would cancel whichever turn completed first, and fail here.
	func testAnInterruptChangesAnOutcomeWithoutChangingFIFOSelection() {
		var reconciler = ClaudeLifecycleReconciler()
		reconciler.openTurn(turnA)
		reconciler.openTurn(turnB)
		_ = reconciler.reconcile(stamp(runState(.running)))
		_ = reconciler.reconcile(stamp(.host(.interruptRequested(target: turnB))))

		_ = reconciler.reconcile(stamp(result()), observedOutcome: .completed)
		_ = reconciler.reconcile(stamp(result()), observedOutcome: .completed)

		XCTAssertEqual(
			reconciler.reconcile(stamp(runState(.idle))),
			[.complete(turn: turnA, outcome: .completed, trigger: .idleBoundary)],
			"the interrupt aimed at B must not divert the first boundary onto B"
		)
		XCTAssertEqual(
			reconciler.reconcile(stamp(runState(.idle))),
			[.complete(turn: turnB, outcome: .cancelled, trigger: .idleBoundary)],
			"B is cancelled because it was named, not because it completed second"
		)
	}

	// MARK: - Terminal host signals

	func testTransportCloseFailsTurnsThatNeverProducedAResult() {
		var reconciler = ClaudeLifecycleReconciler()
		reconciler.openTurn(turnA)

		XCTAssertEqual(
			reconciler.reconcile(stamp(.host(.transportClosed))),
			[.complete(turn: turnA, outcome: .failed, trigger: .transportEndedStale)],
			"EOF under an open turn is evidence about how it ended; leaving it open strands it"
		)
	}

	/// A deliberate teardown is NOT evidence about how an open turn ended, so a
	/// statusless turn is abandoned rather than failed — but it still leaves.
	func testShutdownAbandonsAStatuslessOpenTurnRatherThanCompletingIt() {
		var reconciler = ClaudeLifecycleReconciler()
		reconciler.openTurn(turnA)

		XCTAssertEqual(
			reconciler.reconcile(stamp(.host(.shutdownRequested))),
			[.abandon(turn: turnA)],
			"shutdown must not invent an outcome, and must not strand the generation either"
		)
	}

	func testShutdownDrainsObservedStatusesAndAbandonsTheRest() {
		var reconciler = ClaudeLifecycleReconciler()
		reconciler.openTurn(turnA)
		reconciler.openTurn(turnB)
		_ = reconciler.reconcile(stamp(runState(.running)))
		_ = reconciler.reconcile(stamp(result()), observedOutcome: .failed)

		XCTAssertEqual(
			reconciler.reconcile(stamp(.host(.shutdownRequested))),
			[
				.complete(turn: turnA, outcome: .failed, trigger: .teardownDrain),
				.abandon(turn: turnB)
			],
			"an observed status is drained with its own outcome; a statusless turn is abandoned"
		)
	}

	/// Shutdown is terminal for its transport: nothing it left behind may absorb a
	/// later turn's result.
	func testAnAbandonedGenerationCannotBeMatchedAfterTheTransportIsReplaced() {
		var reconciler = ClaudeLifecycleReconciler()
		reconciler.openTurn(turnA)
		_ = reconciler.reconcile(stamp(.host(.interruptRequested(target: turnA))))
		XCTAssertEqual(
			reconciler.reconcile(stamp(.host(.shutdownRequested))),
			[.abandon(turn: turnA)]
		)

		let newEpoch = ClaudeTransportEpoch.initial.next()
		_ = reconciler.reconcile(stamp(.host(.transportReestablished), epoch: newEpoch))
		reconciler.openTurn(turnB)

		XCTAssertEqual(
			reconciler.reconcile(stamp(result(), epoch: newEpoch), observedOutcome: .completed),
			[.complete(turn: turnB, outcome: .completed, trigger: .resultWithoutIdleBoundary)],
			"the abandoned generation must neither absorb the new result nor leak its interrupt"
		)
	}

	/// Existing production semantics: a protocol failure fails everything still
	/// open. A deferred status was awaiting a boundary that will never arrive, so
	/// it is not a completed turn.
	func testProtocolFailureFailsEveryStillOpenTurnIncludingDeferredOnes() {
		var reconciler = ClaudeLifecycleReconciler()
		reconciler.openTurn(turnA)
		reconciler.openTurn(turnB)
		_ = reconciler.reconcile(stamp(runState(.running)))
		_ = reconciler.reconcile(stamp(result()), observedOutcome: .completed)

		XCTAssertEqual(
			reconciler.reconcile(stamp(.host(.protocolFailureOccurred))),
			[
				.complete(turn: turnA, outcome: .failed, trigger: .protocolFailure),
				.complete(turn: turnB, outcome: .failed, trigger: .protocolFailure)
			],
			"a deferred status is not a completed turn — everything open fails"
		)
	}

	// MARK: - Replay

	func testInputsFromASupersededEpochAreIgnoredAsReplay() {
		var reconciler = ClaudeLifecycleReconciler()
		reconciler.openTurn(turnA)
		let newEpoch = ClaudeTransportEpoch.initial.next()
		_ = reconciler.reconcile(stamp(.host(.transportReestablished), epoch: newEpoch))

		let late = reconciler.reconcile(stamp(result(), epoch: .initial), observedOutcome: .completed)
		XCTAssertEqual(
			late,
			[.ignoreReplay],
			"a frame stamped against the dead transport must not act on live state"
		)
	}

	// MARK: - Defect 1 — idle before result

	/// Characterization pinned that an idle arriving before its result is dropped
	/// silently, stranding the turn until the fallback timer fires. The
	/// reconciler remembers the idle instead, so the result completes at once.
	func testIdleArrivingBeforeItsResultIsRememberedAndCompletesAtResultTime() {
		var reconciler = ClaudeLifecycleReconciler()
		reconciler.openTurn(turnA)

		XCTAssertEqual(reconciler.reconcile(stamp(runState(.idle))), [.observe], "an early idle completes nothing yet")

		XCTAssertEqual(
			reconciler.reconcile(stamp(result()), observedOutcome: .completed),
			[.complete(turn: turnA, outcome: .completed, trigger: .rememberedIdleAtResult)],
			"the remembered idle lets the result complete immediately instead of waiting for the fallback"
		)
	}

	/// The remembered idle is single-use: it must not complete a second, later turn.
	func testARememberedIdleIsConsumedByExactlyOneResult() {
		var reconciler = ClaudeLifecycleReconciler()
		reconciler.openTurn(turnA)
		reconciler.openTurn(turnB)

		_ = reconciler.reconcile(stamp(runState(.idle)))
		XCTAssertEqual(
			reconciler.reconcile(stamp(result()), observedOutcome: .completed),
			[.complete(turn: turnA, outcome: .completed, trigger: .rememberedIdleAtResult)]
		)
		XCTAssertEqual(
			reconciler.reconcile(stamp(result()), observedOutcome: .completed),
			[.defer(turn: turnB)],
			"the second result must defer normally — one early idle closes one turn"
		)
	}

	// MARK: - Defect 2 — duplicate result

	/// Characterization pinned that a duplicate result queues a SECOND deferred
	/// status, which survives to the fallback and is quarantined there. The
	/// reconciler quarantines it at result time, when the duplication is visible.
	func testDuplicateResultForTheSameTurnIsQuarantinedImmediately() {
		var reconciler = ClaudeLifecycleReconciler()
		reconciler.openTurn(turnA)
		_ = reconciler.reconcile(stamp(runState(.running)))

		XCTAssertEqual(
			reconciler.reconcile(stamp(result()), observedOutcome: .completed),
			[.defer(turn: turnA)]
		)
		XCTAssertEqual(
			reconciler.reconcile(stamp(result()), observedOutcome: .completed),
			[.quarantine(.duplicateResultForOpenTurn)],
			"the duplicate must be quarantined where it happens, not left to strand a later turn"
		)

		// The real turn still completes normally.
		XCTAssertEqual(
			reconciler.reconcile(stamp(runState(.idle))),
			[.complete(turn: turnA, outcome: .completed, trigger: .idleBoundary)],
			"quarantining the duplicate must not disturb the genuine completion"
		)
	}

	func testResultWithNoOpenTurnIsQuarantinedThroughTheTaskZeroSite() {
		var reconciler = ClaudeLifecycleReconciler()

		XCTAssertEqual(
			reconciler.reconcile(stamp(result()), observedOutcome: .completed),
			[.quarantine(.resultMessageStopWithoutPendingTurn)],
			"an unmatched result reuses the existing Task 0 drift site rather than inventing a channel"
		)
	}

	// MARK: - Defect 3 — interrupt targeting

	/// Characterization pinned a controller-wide flag being consumed by whichever
	/// result landed first. A generation-targeted interrupt cancels the turn it
	/// named, and leaves the other turn's own status intact.
	func testInterruptCancelsOnlyTheTurnItNamed() {
		var reconciler = ClaudeLifecycleReconciler()
		reconciler.openTurn(turnA)
		reconciler.openTurn(turnB)
		_ = reconciler.reconcile(stamp(runState(.running)))

		XCTAssertEqual(
			reconciler.reconcile(stamp(.host(.interruptRequested(target: turnB)))),
			[.observe],
			"an interrupt records intent; it completes nothing by itself"
		)

		_ = reconciler.reconcile(stamp(result()), observedOutcome: .completed)
		XCTAssertEqual(
			reconciler.reconcile(stamp(runState(.idle))),
			[.complete(turn: turnA, outcome: .completed, trigger: .idleBoundary)],
			"the turn that was NOT interrupted keeps its observed status"
		)

		_ = reconciler.reconcile(stamp(result()), observedOutcome: .completed)
		XCTAssertEqual(
			reconciler.reconcile(stamp(runState(.idle))),
			[.complete(turn: turnB, outcome: .cancelled, trigger: .idleBoundary)],
			"the interrupted turn is cancelled, however late its result arrives"
		)
	}

	// MARK: - Defect 4 — teardown loses an observed terminal status

	/// Characterization pinned that `shutdown()` clears turn identities before
	/// draining, dropping an already-observed terminal status with no completion
	/// and no drift. The reconciler sees shutdown while the status is still
	/// pending and completes it with the status that was actually observed.
	func testShutdownCompletesAnObservedTerminalStatusThatLegacyDrops() {
		var reconciler = ClaudeLifecycleReconciler()
		reconciler.openTurn(turnA)
		_ = reconciler.reconcile(stamp(runState(.running)))
		_ = reconciler.reconcile(stamp(result()), observedOutcome: .failed)

		XCTAssertEqual(
			reconciler.reconcile(stamp(.host(.shutdownRequested))),
			[.complete(turn: turnA, outcome: .failed, trigger: .teardownDrain)],
			"an observed terminal status must not be lost to teardown, and keeps its own status"
		)
	}

	func testTransportCloseDrainsEveryPendingTerminalStatusInOrder() {
		var reconciler = ClaudeLifecycleReconciler()
		reconciler.openTurn(turnA)
		reconciler.openTurn(turnB)
		_ = reconciler.reconcile(stamp(runState(.running)))
		_ = reconciler.reconcile(stamp(result()), observedOutcome: .completed)
		_ = reconciler.reconcile(stamp(runState(.idle)))
		_ = reconciler.reconcile(stamp(result()), observedOutcome: .failed)

		XCTAssertEqual(
			reconciler.reconcile(stamp(.host(.transportClosed))),
			[.complete(turn: turnB, outcome: .failed, trigger: .teardownDrain)],
			"EOF drains what is still pending, in FIFO order"
		)
	}

	/// If teardown finds a terminal status whose turn identity cannot be
	/// reconciled, it is quarantined and recorded — never retargeted onto some
	/// other turn.
	func testTeardownQuarantinesATerminalStatusWithNoReconcilableTurn() {
		var reconciler = ClaudeLifecycleReconciler()
		reconciler.openTurn(turnA)
		_ = reconciler.reconcile(stamp(runState(.running)))
		_ = reconciler.reconcile(stamp(result()), observedOutcome: .completed)
		reconciler.forgetTurn(turnA)

		XCTAssertEqual(
			reconciler.reconcile(stamp(.host(.shutdownRequested))),
			[.quarantine(.terminalStatusWithoutTurnAtTeardown)],
			"an unreconcilable status is quarantined, never replayed onto another turn"
		)
	}

	// MARK: - Session corroboration

	/// A result whose session identity contradicts the one already observed must
	/// not silently fall back to FIFO matching.
	func testResultFromAContradictorySessionIsQuarantinedNotFIFOMatched() {
		var reconciler = ClaudeLifecycleReconciler()
		reconciler.openTurn(turnA)
		_ = reconciler.reconcile(stamp(result(sessionID: "session-1")), observedOutcome: .completed)
		_ = reconciler.reconcile(stamp(runState(.idle)))

		reconciler.openTurn(turnB)
		XCTAssertEqual(
			reconciler.reconcile(stamp(result(sessionID: "session-2")), observedOutcome: .completed),
			[.quarantine(.resultForUnrecognizedSession)],
			"a contradictory session identity must block FIFO attribution"
		)
	}

	/// Corroboration only applies once an identity is known; the first observed
	/// session establishes it, and results that omit the id stay attributable.
	func testFirstObservedSessionEstablishesIdentityAndOmittedIDsStillMatch() {
		var reconciler = ClaudeLifecycleReconciler()
		reconciler.openTurn(turnA)

		// Completes rather than defers: no boundary capability yet. What this test
		// guards is that the session id was ACCEPTED, not which trigger fired.
		XCTAssertEqual(
			reconciler.reconcile(stamp(result(sessionID: "session-1")), observedOutcome: .completed),
			[.complete(turn: turnA, outcome: .completed, trigger: .resultWithoutIdleBoundary)],
			"the first observed session establishes identity rather than conflicting with it"
		)
		// No idle is needed to free turnA any more — its own result completed it.
		// Leaving one in would establish a remembered boundary and drag boundary
		// mechanics into a test about session identity.
		reconciler.openTurn(turnB)
		XCTAssertEqual(
			reconciler.reconcile(stamp(result()), observedOutcome: .completed),
			[.complete(turn: turnB, outcome: .completed, trigger: .resultWithoutIdleBoundary)],
			"a result that carries no session id is not treated as a contradiction"
		)
	}
}
