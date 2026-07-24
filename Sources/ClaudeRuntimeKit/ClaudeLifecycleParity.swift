import Foundation

/// Parity comparison between the legacy completion lane and the normalized
/// reconciler lane (Slice 4b step 5).
///
/// Design rule, learned the hard way: **a comparator that cannot see a field
/// cannot report a divergence in it.** The Slice 2/3 parity gate was
/// structurally blind because its comparable form omitted every token field,
/// which is how a wholly absent usage model survived two slices. `R11e` pins
/// those fields now and must never be narrowed.
///
/// The same trap is live here in a different shape. For the early-idle defect
/// both lanes complete the SAME turn with the SAME outcome — legacy after
/// waiting out the fallback timer, the reconciler immediately at result time. A
/// comparison keyed on `(turn, outcome)` would call that parity. So
/// `ClaudeCompletionTrigger` is a compared field, not metadata.
///
/// Parity is NOT reduced to counts, and there are no broad ignore categories.
/// Every difference is emitted as a specific, field-level mismatch naming the
/// turn it concerns.

/// One completion, in whichever lane produced it. Every field participates in
/// the comparison; adding a field here without adding it to `==` would
/// reintroduce exactly the blindness this type exists to prevent.
public struct ClaudeReconciledCompletion: Equatable, Sendable {
	public let turn: ClaudeTurnGeneration
	public let outcome: ClaudeTurnOutcome
	public let trigger: ClaudeCompletionTrigger

	public init(
		turn: ClaudeTurnGeneration,
		outcome: ClaudeTurnOutcome,
		trigger: ClaudeCompletionTrigger
	) {
		self.turn = turn
		self.outcome = outcome
		self.trigger = trigger
	}
}

/// A specific, field-level difference. Deliberately never a category — each case
/// names the turn involved and both lanes' values, so a report can be read
/// without re-running the scenario.
public enum ClaudeLifecycleParityMismatch: Equatable, Sendable {
	/// Legacy completed a turn the normalized lane did not.
	case completedOnlyInLegacy(ClaudeReconciledCompletion)
	/// The normalized lane completed a turn legacy did not.
	case completedOnlyInNormalized(ClaudeReconciledCompletion)
	/// Both completed the turn, with different outcomes.
	case outcomeDiffers(
		turn: ClaudeTurnGeneration,
		legacy: ClaudeTurnOutcome,
		normalized: ClaudeTurnOutcome
	)
	/// Both completed the turn with the same outcome, by different mechanisms.
	/// This is the case the pre-trigger comparator could not see.
	case triggerDiffers(
		turn: ClaudeTurnGeneration,
		legacy: ClaudeCompletionTrigger,
		normalized: ClaudeCompletionTrigger
	)
	/// Both completed the turn, at different positions in the completion order.
	case orderDiffers(
		turn: ClaudeTurnGeneration,
		legacyIndex: Int,
		normalizedIndex: Int
	)
}

/// The complete set of divergences accepted between the two lanes.
///
/// EMPTY AS OF F3, and deliberately not deleted.
///
/// It held exactly four entries, each a defect that step-1 characterization
/// pinned in the legacy lane: `idleBeforeResultDropped`,
/// `duplicateResultQueuedTwice`, `interruptConsumedByWrongTurn` and
/// `shutdownLosesObservedTerminalStatus`. All four were resolved together in the
/// production flip, and parity now compares the two SEMANTIC PROJECTION modes
/// running under one lifecycle authority — a comparison whose correct answer is
/// zero mismatches.
///
/// The type survives so that re-accepting a divergence is a deliberate act that
/// fails a named assertion, rather than a quiet addition. An empty enum cannot
/// carry a raw value, hence the shape change; `allCases.isEmpty` is asserted by
/// `ClaudeLifecycleParityTests`, and the boundary gate requires both the type and
/// that assertion to keep existing. A guard that can be deleted is not a guard.
public enum ClaudeExpectedLifecycleDivergence: CaseIterable, Sendable {}

public enum ClaudeLifecycleParity {

	/// Compares the two lanes turn by turn. Output order is stable (by turn
	/// generation, then by mismatch kind) so a report is diffable.
	public static func compare(
		legacy: [ClaudeReconciledCompletion],
		normalized: [ClaudeReconciledCompletion]
	) -> [ClaudeLifecycleParityMismatch] {
		var mismatches: [ClaudeLifecycleParityMismatch] = []

		let legacyByTurn = indexed(legacy)
		let normalizedByTurn = indexed(normalized)
		let allTurns = Set(legacyByTurn.keys).union(normalizedByTurn.keys).sorted()

		for turn in allTurns {
			switch (legacyByTurn[turn], normalizedByTurn[turn]) {
			case (.some(let l), .none):
				mismatches.append(.completedOnlyInLegacy(l.completion))
			case (.none, .some(let n)):
				mismatches.append(.completedOnlyInNormalized(n.completion))
			case (.some(let l), .some(let n)):
				// Every field is checked. None may be skipped for being
				// "incidental" — that judgment is what went wrong in Slice 2/3.
				if l.completion.outcome != n.completion.outcome {
					mismatches.append(
						.outcomeDiffers(
							turn: turn,
							legacy: l.completion.outcome,
							normalized: n.completion.outcome
						)
					)
				}
				if l.completion.trigger != n.completion.trigger {
					mismatches.append(
						.triggerDiffers(
							turn: turn,
							legacy: l.completion.trigger,
							normalized: n.completion.trigger
						)
					)
				}
				if l.index != n.index {
					mismatches.append(
						.orderDiffers(turn: turn, legacyIndex: l.index, normalizedIndex: n.index)
					)
				}
			case (.none, .none):
				continue
			}
		}
		return mismatches
	}

	private struct Positioned {
		let completion: ClaudeReconciledCompletion
		let index: Int
	}

	/// Keys completions by turn. A turn completing twice in one lane is itself a
	/// fault, so the FIRST completion wins and the duplicate is left visible as a
	/// count difference rather than silently overwriting.
	private static func indexed(
		_ completions: [ClaudeReconciledCompletion]
	) -> [ClaudeTurnGeneration: Positioned] {
		var result: [ClaudeTurnGeneration: Positioned] = [:]
		for (index, completion) in completions.enumerated() where result[completion.turn] == nil {
			result[completion.turn] = Positioned(completion: completion, index: index)
		}
		return result
	}
}
