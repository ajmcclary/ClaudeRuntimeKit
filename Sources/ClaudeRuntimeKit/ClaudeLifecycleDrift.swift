import Foundation

/// Provider-controlled lifecycle ordering that violated an app-side expectation
/// (Program A; Slice 4b Task 0).
///
/// **Drift is degraded-but-survivable, never process-fatal.** These sites were
/// previously `assertionFailure`, which traps in Debug: a provider that reordered
/// or duplicated a lifecycle frame could crash a developer build. Ordering is not
/// ours to guarantee — the CLI controls it — so an unexpected order is an
/// observation, not a programmer error.
///
/// A drift record is an IDENTITY, not a payload. It deliberately carries no turn
/// id, session id, or payload, so it can never become a leak channel. Counting is
/// by stable `fingerprint`, matching `ClaudeRuntimeDiagnostic`'s contract.
public struct ClaudeLifecycleDrift: Equatable, Sendable {
	public enum Site: String, CaseIterable, Sendable {
		/// A `result`/`message_stop` arrived with no turn open.
		case resultMessageStopWithoutPendingTurn
		// REMOVED at F3: `deferredIdleCompletionWithoutPendingTurn` and
		// `idleFallbackWithoutPendingTurn`. Both described a disagreement between
		// two independently mutated structures — an app-side status queue and the
		// turn queue — where a status was popped and only then found to have no
		// turn. The reconciler holds `(generation, outcome)` as ONE record, so that
		// disagreement cannot occur and the sites are unreachable by construction.
		// Retaining them would advertise diagnostics that can never fire, and
		// mapping newer failures onto them would conflate different ownership
		// defects. Their coverage moved to `completionForUnknownGeneration` and
		// `terminalStatusWithoutTurnAtTeardown`.
		/// A second `result` arrived for a turn whose terminal status was already
		/// observed (Slice 4b reconciler).
		case duplicateResultForOpenTurn
		/// Teardown found an observed terminal status whose turn identity could
		/// not be reconciled. Quarantined, never retargeted (Slice 4b reconciler).
		case terminalStatusWithoutTurnAtTeardown
		/// A `result` carried a session identity contradicting the one already
		/// observed, so FIFO attribution was refused (Slice 4b reconciler).
		case resultForUnrecognizedSession
		/// The interpreter was handed a decision naming a generation that the turn
		/// ledger does not hold. Identity-free by construction: the whole failure is
		/// that no identity could be resolved, so none can be reported. Nothing is
		/// emitted and no other record is consumed in its place (F3).
		case completionForUnknownGeneration
	}

	public let site: Site

	public init(site: Site) {
		self.site = site
	}

	/// Stable across occurrences — derived from identity only, never content.
	public var fingerprint: String {
		"lifecycleDrift|site=\(site.rawValue)"
	}

	/// Redacted by construction: built from the site name, never from a payload.
	public var summary: String {
		switch site {
		case .resultMessageStopWithoutPendingTurn:
			return "Lifecycle drift: result/message_stop arrived with no open turn"
		case .duplicateResultForOpenTurn:
			return "Lifecycle drift: duplicate result for a turn already holding a terminal status"
		case .terminalStatusWithoutTurnAtTeardown:
			return "Lifecycle drift: observed terminal status had no reconcilable turn at teardown"
		case .resultForUnrecognizedSession:
			return "Lifecycle drift: result carried a session identity contradicting the observed one"
		case .completionForUnknownGeneration:
			return "Lifecycle drift: a completion named a generation the turn ledger does not hold"
		}
	}
}

/// Bounded, single owner for lifecycle-drift observation.
///
/// Bounded on purpose: a provider stuck in a drift loop must not grow memory.
/// The retained per-site count saturates at `perSiteCap`, while
/// `observedCount(for:)` keeps counting so the true scale stays visible.
public final class ClaudeLifecycleDriftRecorder: @unchecked Sendable {
	public struct Snapshot: Sendable {
		private let retained: [ClaudeLifecycleDrift.Site: Int]
		private let observed: [ClaudeLifecycleDrift.Site: Int]
		public let saturatedSites: Set<ClaudeLifecycleDrift.Site>

		init(
			retained: [ClaudeLifecycleDrift.Site: Int],
			observed: [ClaudeLifecycleDrift.Site: Int],
			saturatedSites: Set<ClaudeLifecycleDrift.Site>
		) {
			self.retained = retained
			self.observed = observed
			self.saturatedSites = saturatedSites
		}

		/// Retained (capped) count for a site.
		public func count(for site: ClaudeLifecycleDrift.Site) -> Int {
			retained[site] ?? 0
		}

		/// True number observed, uncapped.
		public func observedCount(for site: ClaudeLifecycleDrift.Site) -> Int {
			observed[site] ?? 0
		}

		/// Sum of retained counts.
		public var totalCount: Int {
			retained.values.reduce(0, +)
		}

		public var isEmpty: Bool { totalCount == 0 }
	}

	public static let defaultPerSiteCap = 32

	private let perSiteCap: Int
	private let lock = NSLock()
	private var retained: [ClaudeLifecycleDrift.Site: Int] = [:]
	private var observed: [ClaudeLifecycleDrift.Site: Int] = [:]

	public init(perSiteCap: Int = ClaudeLifecycleDriftRecorder.defaultPerSiteCap) {
		self.perSiteCap = max(1, perSiteCap)
	}

	@discardableResult
	public func record(_ site: ClaudeLifecycleDrift.Site) -> ClaudeLifecycleDrift {
		lock.lock()
		defer { lock.unlock() }
		observed[site, default: 0] += 1
		let current = retained[site] ?? 0
		if current < perSiteCap {
			retained[site] = current + 1
		}
		return ClaudeLifecycleDrift(site: site)
	}

	public func snapshot() -> Snapshot {
		lock.lock()
		defer { lock.unlock() }
		let saturated = Set(retained.filter { $0.value >= perSiteCap }.keys)
		return Snapshot(retained: retained, observed: observed, saturatedSites: saturated)
	}
}
