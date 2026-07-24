import Foundation

/// Pure, replay-safe accumulator for Claude token usage (Slice 4a).
///
/// Deduplicates by `ClaudeUsageIdentity` and excludes child/subagent scopes from
/// the top-level turn total. This runs in SHADOW MODE in Slice 4a — production
/// accounting is unchanged and still flows through `ClaudeContextUsageEstimator`,
/// which is deliberately NOT idempotent (pinned defect: two finalizations of one
/// logical turn persist two rows). The production expectation changes only at
/// the flip commit.
public struct ClaudeUsageLedger: Equatable, Sendable {
	public private(set) var turnTotal: ClaudeUsageBreakdown = .zero
	public private(set) var childTotal: ClaudeUsageBreakdown = .zero
	public private(set) var latestContextUsedTokens: Int?
	public private(set) var appliedIdentities: [ClaudeUsageIdentity] = []

	private var seen: Set<ClaudeUsageIdentity> = []

	public enum Ingestion: Equatable, Sendable {
		/// Counted toward the top-level turn.
		case applied
		/// Already seen — a replay, resume, or duplicate delivery. No-op.
		case duplicateIgnored
		/// Counted toward `childTotal` only; never inflates the parent turn.
		case childExcluded
	}

	public init() {}

	@discardableResult
	public mutating func ingest(
		identity: ClaudeUsageIdentity,
		scope: ClaudeUsageScope,
		breakdown: ClaudeUsageBreakdown
	) -> Ingestion {
		guard seen.insert(identity).inserted else { return .duplicateIgnored }
		appliedIdentities.append(identity)

		switch scope {
		case .child:
			// Tracked separately so subagent consumption stays observable without
			// inflating the parent turn.
			childTotal = childTotal.adding(breakdown)
			return .childExcluded
		case .topLevel:
			turnTotal = turnTotal.adding(breakdown)
			latestContextUsedTokens = breakdown.contextUsedTokens
			return .applied
		}
	}
}
