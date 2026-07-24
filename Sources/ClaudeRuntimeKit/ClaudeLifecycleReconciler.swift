import Foundation

/// Reconciles stamped lifecycle inputs into explicit decisions (Slice 4b step 4).
///
/// Placement: this belongs in the package on SEMANTIC ownership, not merely
/// technical purity. Purity alone would justify moving almost anything here.
/// It qualifies because:
///
///   - it interprets Claude lifecycle PROTOCOL behavior;
///   - it is keyed on provider-neutral generations, not RepoPrompt turn UUIDs;
///   - it has no controller, transcript, persistence, timer, process, or UI
///     dependency;
///   - it produces value decisions it cannot execute;
///   - any other Claude runtime consumer should want these same replay,
///     idle/result, interruption, session-mismatch, and teardown rules.
///
/// The app remains AUTHORITATIVE: it owns the sole instance, opens turns and
/// maps generations to real turn UUIDs, supplies observed outcomes and host
/// signals, decides whether and how to apply a `.complete`, and performs
/// emission and persistence. During Slice 4b it applies none of them.
///
///     ClaudeRuntimeCore:  wire facts -> reconciliation decision
///     RepoPrompt app:     decision -> turn UUID -> emitted completion -> persistence
///
/// R12 ratchets that split, and continues to after the production flip.

/// The outcome a turn is reconciled to. Mirrors the controller's `TurnStatus`
/// without importing it.
public enum ClaudeTurnOutcome: Equatable, Sendable {
	case completed
	case cancelled
	case failed
}

/// WHY a turn completed.
///
/// Carried as a first-class field because two lanes can complete the same turn
/// with the same outcome by different mechanisms, and that difference is a real
/// divergence. A parity comparison that cannot see the trigger reports parity
/// for the early-idle defect, where legacy waits out the fallback timer and the
/// reconciler completes at result time — same turn, same outcome, seconds apart.
/// That is the Slice 2/3 blindness in a new shape.
public enum ClaudeCompletionTrigger: String, Equatable, Sendable, CaseIterable {
	// REMOVED at F3: `legacyImmediate`. It named a completion decided from
	// capability state held on the CONTROLLER, outside the reconciler — a second
	// lifecycle authority. `resultWithoutIdleBoundary` reaches the same conclusion
	// from the reconciler's own capability model, and R12g forbids the old spelling
	// from reappearing in controller code.
	/// The provider never demonstrated an idle-boundary capability, so the result
	/// itself is the completion boundary.
	///
	/// This is the ORDINARY production path, not an edge case: real 2.1.215 does not
	/// emit `session_state_changed` at all. Deferring these turns to the fallback
	/// timer instead would add `authoritativeTurnIdleFallbackSeconds` (1.0s by
	/// default) to every turn.
	case resultWithoutIdleBoundary
	/// The authoritative `idle` boundary arrived.
	case idleBoundary
	/// `idle` never arrived and the fallback timer fired.
	case fallbackTimer
	/// A deferred status was drained during shutdown or transport close.
	case teardownDrain
	/// The transport ended with turns still open and no result observed.
	case transportEndedStale
	/// A protocol failure drained the queue.
	case protocolFailure
	/// A completion boundary had already been observed when the result arrived,
	/// so the result completed immediately. Normalized lane only.
	case rememberedIdleAtResult
}

public enum ClaudeLifecycleDecision: Equatable, Sendable {
	/// Recorded; nothing to act on.
	case observe
	/// A terminal status was observed, but the completion boundary has not
	/// arrived. The turn stays open.
	case `defer`(turn: ClaudeTurnGeneration)
	/// The turn is finished, with this outcome, by this mechanism.
	case complete(
		turn: ClaudeTurnGeneration,
		outcome: ClaudeTurnOutcome,
		trigger: ClaudeCompletionTrigger
	)
	/// Stamped against a superseded transport; it must not touch live state.
	case ignoreReplay
	/// The turn is being dropped WITHOUT an outcome, because nothing was ever
	/// observed about how it ended and the session is going away.
	///
	/// Distinct from `complete` and from `quarantine`: no status is being reported
	/// and none was lost. It exists so a deliberate shutdown can clear a statusless
	/// turn from both the reconciler and the app ledger without inventing an
	/// outcome for it — leaving it open would strand the generation instead.
	case abandon(turn: ClaudeTurnGeneration)
	/// Cannot be reconciled. Discarded and recorded as drift — never retargeted
	/// onto some other turn.
	case quarantine(ClaudeLifecycleDrift.Site)
}

/// One stamped input paired with what the reconciler decided about it.
///
/// A single record rather than parallel arrays on purpose: positionally-coupled
/// collections with nothing binding them are the exact shape of the legacy
/// turn-ID / deferred-status pairing that step 1 characterized as a defect.
public struct ClaudeShadowLifecycleRecord: Equatable, Sendable {
	public let stamped: ClaudeStampedLifecycleInput
	public let decisions: [ClaudeLifecycleDecision]

	public init(stamped: ClaudeStampedLifecycleInput, decisions: [ClaudeLifecycleDecision]) {
		self.stamped = stamped
		self.decisions = decisions
	}
}

public struct ClaudeLifecycleReconciler: Sendable {

	/// Terminal status observed for a turn, waiting for its completion boundary.
	private struct DeferredOutcome: Equatable {
		let turn: ClaudeTurnGeneration
		let outcome: ClaudeTurnOutcome
	}

	private var epoch: ClaudeTransportEpoch = .initial
	private var openTurns: [ClaudeTurnGeneration] = []
	private var deferred: [DeferredOutcome] = []
	private var interruptedTurns: Set<ClaudeTurnGeneration> = []
	private var observedSessionID: String?

	/// A completion boundary that arrived before the terminal status it belongs
	/// to. Characterization pinned legacy dropping this, stranding the turn until
	/// the fallback timer. Remembering it lets the result complete at once.
	/// Single-use: one early idle closes exactly one turn.
	private var pendingIdleBoundary = false

	/// Whether this transport has ever produced a run-state boundary.
	///
	/// Capability, not a boundary: it records that the provider CAN mark idle, which
	/// is what decides whether an ordinary result should wait for a boundary or is
	/// itself the boundary. Modeled here rather than on the controller so the
	/// decision belongs to the reconciler — holding it host-side is what made
	/// `legacyImmediate` a competing lifecycle authority.
	///
	/// Reset when a new transport is established: a capability demonstrated by a
	/// dead transport says nothing about its replacement.
	private var observedIdleBoundaryCapability = false

	public init() {}

	/// Whether any turn is holding a terminal status that has not yet reached its
	/// completion boundary.
	///
	/// A read-only FACT, deliberately not the deferred collection itself: the host
	/// needs it to decide whether its fallback timer should be armed, and exposing
	/// the queue would invite a second owner to mirror it — the positional coupling
	/// this design exists to remove.
	public var hasDeferredOutcomes: Bool { !deferred.isEmpty }

	/// Registers a newly opened turn. Opening is a host action, not a wire event.
	public mutating func openTurn(_ generation: ClaudeTurnGeneration) {
		openTurns.append(generation)
	}

	/// Drops a turn without completing it. Exists so the app can keep the
	/// reconciler's view consistent when production discards a turn by a path the
	/// reconciler does not model.
	public mutating func forgetTurn(_ generation: ClaudeTurnGeneration) {
		openTurns.removeAll { $0 == generation }
		interruptedTurns.remove(generation)
	}

	public mutating func reconcile(
		_ stamped: ClaudeStampedLifecycleInput,
		observedOutcome: ClaudeTurnOutcome? = nil
	) -> [ClaudeLifecycleDecision] {
		// Epoch check first: a frame from a dead transport must not act on live
		// state, whatever it says.
		if stamped.epoch < epoch { return [.ignoreReplay] }

		switch stamped.input {
		case .host(let signal):
			return reconcileHost(signal, stampedEpoch: stamped.epoch)
		case .wire(let event):
			return reconcileWire(event, observedOutcome: observedOutcome)
		}
	}

	// MARK: - Host signals

	private mutating func reconcileHost(
		_ signal: ClaudeHostLifecycleSignal,
		stampedEpoch: ClaudeTransportEpoch
	) -> [ClaudeLifecycleDecision] {
		switch signal {
		case .transportReestablished:
			epoch = stampedEpoch
			// A boundary remembered against the dead transport means nothing now,
			// and neither does a capability it demonstrated.
			pendingIdleBoundary = false
			observedIdleBoundaryCapability = false
			return [.observe]

		case .interruptRequested(let target):
			// Records intent against a NAMED turn. Completes nothing by itself —
			// the outcome is applied when that turn's own result is reconciled,
			// however late it arrives.
			interruptedTurns.insert(target)
			return [.observe]

		case .idleFallbackFired:
			guard !deferred.isEmpty else { return [.observe] }
			return [completeNextDeferred(trigger: .fallbackTimer)]

		case .shutdownRequested:
			// Teardown must not lose a status that was already observed. Anything
			// unreconcilable is quarantined, never retargeted.
			var decisions: [ClaudeLifecycleDecision] = []
			while !deferred.isEmpty {
				decisions.append(completeNextDeferred(trigger: .teardownDrain))
			}
			// Turns with NO observed status are abandoned, not completed: a
			// deliberate teardown is not evidence about how they ended, so inventing
			// an outcome would be the guess this design forbids. They must still
			// LEAVE, though — a turn left open here strands its generation.
			for turn in openTurns {
				decisions.append(.abandon(turn: turn))
			}
			// Shutdown is terminal for this transport: no open, deferred or
			// interrupted state may survive it.
			openTurns.removeAll()
			deferred.removeAll()
			interruptedTurns.removeAll()
			pendingIdleBoundary = false
			return decisions.isEmpty ? [.observe] : decisions

		case .transportClosed:
			// Observed statuses drain first, keeping their outcomes.
			var decisions: [ClaudeLifecycleDecision] = []
			while !deferred.isEmpty {
				decisions.append(completeNextDeferred(trigger: .teardownDrain))
			}
			// Then anything still open: the transport ended underneath a turn that
			// never produced a result. Unlike a deliberate shutdown, EOF IS evidence
			// about how those turns ended, and leaving them open strands them.
			decisions.append(contentsOf: completeAllOpenTurns(trigger: .transportEndedStale))
			return decisions.isEmpty ? [.observe] : decisions

		case .protocolFailureOccurred:
			// Existing production semantics, kept deliberately: EVERY still-open turn
			// fails. A deferred status is not a completed turn — it was awaiting an
			// authoritative boundary that now will never arrive — so preserving it
			// would be a behavioral change outside the four approved divergences.
			// Reconsidering that policy is a separate, separately reviewed change.
			deferred.removeAll()
			pendingIdleBoundary = false
			let decisions = completeAllOpenTurns(trigger: .protocolFailure)
			return decisions.isEmpty ? [.observe] : decisions
		}
	}

	/// Fails every remaining open turn, oldest first.
	///
	/// Only reached from terminal host signals, where no further evidence about
	/// these turns can arrive. `complete` removes each turn as it goes, so this
	/// drains rather than looping.
	private mutating func completeAllOpenTurns(
		trigger: ClaudeCompletionTrigger
	) -> [ClaudeLifecycleDecision] {
		var decisions: [ClaudeLifecycleDecision] = []
		while let turn = openTurns.first {
			decisions.append(complete(turn: turn, outcome: .failed, trigger: trigger))
		}
		return decisions
	}

	/// Pops the head deferred status and either completes its turn or quarantines
	/// it. The pop happens first in both branches, so an unreconcilable status is
	/// discarded rather than left to close an unrelated later turn.
	private mutating func completeNextDeferred(
		trigger: ClaudeCompletionTrigger
	) -> ClaudeLifecycleDecision {
		let next = deferred.removeFirst()
		guard openTurns.contains(next.turn) else {
			return .quarantine(.terminalStatusWithoutTurnAtTeardown)
		}
		return complete(turn: next.turn, outcome: next.outcome, trigger: trigger)
	}

	private mutating func complete(
		turn: ClaudeTurnGeneration,
		outcome: ClaudeTurnOutcome,
		trigger: ClaudeCompletionTrigger
	) -> ClaudeLifecycleDecision {
		openTurns.removeAll { $0 == turn }
		interruptedTurns.remove(turn)
		return .complete(turn: turn, outcome: outcome, trigger: trigger)
	}

	// MARK: - Wire events

	private mutating func reconcileWire(
		_ event: ClaudeLifecycleEvent,
		observedOutcome: ClaudeTurnOutcome?
	) -> [ClaudeLifecycleDecision] {
		switch event.phase {
		case .childTaskStarted, .childTaskNotification, .childTaskProgress:
			// A child event may never close a top-level turn.
			return [.observe]

		case .runStateChanged(let state):
			// Any top-level run-state frame proves the provider marks boundaries,
			// whatever this particular state is. Recorded before the idle filter so
			// a non-idle state still establishes the capability.
			if event.scope == .topLevel {
				observedIdleBoundaryCapability = true
			}
			guard state == .idle, event.scope == .topLevel else { return [.observe] }
			guard !deferred.isEmpty else {
				// The boundary arrived before its status. Remember it instead of
				// dropping it (defect 1).
				pendingIdleBoundary = true
				return [.observe]
			}
			return [completeNextDeferred(trigger: .idleBoundary)]

		case .resultObserved:
			return [reconcileResult(event, observedOutcome: observedOutcome)]
		}
	}

	private mutating func reconcileResult(
		_ event: ClaudeLifecycleEvent,
		observedOutcome: ClaudeTurnOutcome?
	) -> ClaudeLifecycleDecision {
		// An ambiguous or child-scoped result resolves nothing. Attributing it to
		// the top level by guessing is exactly the bug R12 forbids.
		guard event.scope == .topLevel else { return .observe }

		// Session identity is corroboration. A contradiction blocks FIFO
		// attribution rather than silently falling back to it.
		if let incoming = event.identity.sessionID {
			if let known = observedSessionID, known != incoming {
				return .quarantine(.resultForUnrecognizedSession)
			}
			observedSessionID = incoming
		}

		guard let turn = openTurns.first(where: { candidate in
			!deferred.contains { $0.turn == candidate }
		}) else {
			// Either nothing is open, or every open turn already has a terminal
			// status. Those are different faults and get different sites.
			if openTurns.isEmpty {
				return .quarantine(.resultMessageStopWithoutPendingTurn)
			}
			return .quarantine(.duplicateResultForOpenTurn)
		}

		let outcome = interruptedTurns.contains(turn) ? .cancelled : (observedOutcome ?? .completed)

		if pendingIdleBoundary {
			pendingIdleBoundary = false
			return complete(turn: turn, outcome: outcome, trigger: .rememberedIdleAtResult)
		}

		// No boundary capability demonstrated: nothing further is coming, so the
		// result IS the boundary. Deferring here would strand every turn until the
		// fallback timer, because this is the ordinary path on real 2.1.215.
		//
		// Checked AFTER the remembered boundary above: an early idle proves
		// capability, so that branch can never be reached with this one true.
		if !observedIdleBoundaryCapability {
			return complete(turn: turn, outcome: outcome, trigger: .resultWithoutIdleBoundary)
		}

		deferred.append(DeferredOutcome(turn: turn, outcome: outcome))
		return .defer(turn: turn)
	}
}
