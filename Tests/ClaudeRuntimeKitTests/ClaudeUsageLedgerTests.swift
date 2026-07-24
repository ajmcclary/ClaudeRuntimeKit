import XCTest
@testable import ClaudeRuntimeKit

final class ClaudeUsageLedgerTests: XCTestCase {
	private func identity(_ id: String, _ phase: ClaudeUsagePhase) -> ClaudeUsageIdentity {
		ClaudeUsageIdentity(sessionID: "s1", messageID: id, phase: phase)
	}
	private let sample = ClaudeUsageBreakdown(
		inputTokens: 10, outputTokens: 5,
		cacheCreationInputTokens: 7, cacheReadInputTokens: 100
	)

	func testFirstIngestApplies() {
		var ledger = ClaudeUsageLedger()
		XCTAssertEqual(
			ledger.ingest(identity: identity("msg_1", .turnAggregate), scope: .topLevel, breakdown: sample),
			.applied
		)
		XCTAssertEqual(ledger.turnTotal.inputTokens, 10)
	}

	/// The load-bearing property: replaying the same event is a no-op.
	func testDuplicateIdentityIsIgnored() {
		var ledger = ClaudeUsageLedger()
		let id = identity("msg_1", .turnAggregate)
		_ = ledger.ingest(identity: id, scope: .topLevel, breakdown: sample)
		XCTAssertEqual(ledger.ingest(identity: id, scope: .topLevel, breakdown: sample), .duplicateIgnored)
		XCTAssertEqual(ledger.turnTotal.inputTokens, 10, "duplicate must not double-count")
		XCTAssertEqual(ledger.appliedIdentities.count, 1)
	}

	/// Full replay of a frame sequence converges to the same totals as one pass.
	func testFullReplayIsIdempotent() {
		let ids = [identity("msg_1", .assistantSnapshot), identity("msg_1", .turnAggregate),
				   identity("msg_2", .turnAggregate)]
		var once = ClaudeUsageLedger()
		for id in ids { _ = once.ingest(identity: id, scope: .topLevel, breakdown: sample) }
		var twice = ClaudeUsageLedger()
		for _ in 0..<2 {
			for id in ids { _ = twice.ingest(identity: id, scope: .topLevel, breakdown: sample) }
		}
		XCTAssertEqual(once.turnTotal, twice.turnTotal)
	}

	/// Same message, different phase = different identity. An assistant snapshot
	/// and the turn aggregate are distinct facts, not duplicates.
	func testPhaseDiscriminatesIdentity() {
		var ledger = ClaudeUsageLedger()
		XCTAssertEqual(ledger.ingest(identity: identity("msg_1", .assistantSnapshot), scope: .topLevel, breakdown: sample), .applied)
		XCTAssertEqual(ledger.ingest(identity: identity("msg_1", .turnAggregate), scope: .topLevel, breakdown: sample), .applied)
		XCTAssertEqual(ledger.appliedIdentities.count, 2)
	}

	/// Child/subagent usage must never inflate the top-level turn total.
	func testChildScopeIsExcludedFromTurnTotal() {
		var ledger = ClaudeUsageLedger()
		_ = ledger.ingest(identity: identity("msg_1", .turnAggregate), scope: .topLevel, breakdown: sample)
		XCTAssertEqual(
			ledger.ingest(identity: identity("child_1", .turnAggregate),
						  scope: .child(parentMessageID: "msg_1"), breakdown: sample),
			.childExcluded
		)
		XCTAssertEqual(ledger.turnTotal.inputTokens, 10, "child usage must not inflate the parent turn")
		XCTAssertEqual(ledger.childTotal.inputTokens, 10, "but it stays observable")
	}

	/// Missing messageID must not collapse distinct events into one identity.
	func testNilMessageIDFallsBackToOrdinalIdentity() {
		var ledger = ClaudeUsageLedger()
		let a = ClaudeUsageIdentity(sessionID: "s1", messageID: nil, phase: .turnAggregate, ordinal: 0)
		let b = ClaudeUsageIdentity(sessionID: "s1", messageID: nil, phase: .turnAggregate, ordinal: 1)
		XCTAssertEqual(ledger.ingest(identity: a, scope: .topLevel, breakdown: sample), .applied)
		XCTAssertEqual(ledger.ingest(identity: b, scope: .topLevel, breakdown: sample), .applied)
		XCTAssertEqual(ledger.turnTotal.inputTokens, 20)
	}

	/// With a messageID present the ordinal is ignored for equality, so replay
	/// stays stable even if the producer's counter differs between passes.
	func testOrdinalIsIgnoredWhenMessageIDIsPresent() {
		var ledger = ClaudeUsageLedger()
		let a = ClaudeUsageIdentity(sessionID: "s1", messageID: "msg_1", phase: .turnAggregate, ordinal: 0)
		let b = ClaudeUsageIdentity(sessionID: "s1", messageID: "msg_1", phase: .turnAggregate, ordinal: 99)
		XCTAssertEqual(ledger.ingest(identity: a, scope: .topLevel, breakdown: sample), .applied)
		XCTAssertEqual(ledger.ingest(identity: b, scope: .topLevel, breakdown: sample), .duplicateIgnored)
	}

	/// Different sessions are independent facts even with a colliding messageID.
	func testSessionIDDiscriminatesIdentity() {
		var ledger = ClaudeUsageLedger()
		let a = ClaudeUsageIdentity(sessionID: "s1", messageID: "msg_1", phase: .turnAggregate)
		let b = ClaudeUsageIdentity(sessionID: "s2", messageID: "msg_1", phase: .turnAggregate)
		XCTAssertEqual(ledger.ingest(identity: a, scope: .topLevel, breakdown: sample), .applied)
		XCTAssertEqual(ledger.ingest(identity: b, scope: .topLevel, breakdown: sample), .applied)
	}

	func testLatestContextUsedTracksMostRecentApplied() {
		var ledger = ClaudeUsageLedger()
		_ = ledger.ingest(identity: identity("msg_1", .turnAggregate), scope: .topLevel, breakdown: sample)
		XCTAssertEqual(ledger.latestContextUsedTokens, 117)
		let bigger = ClaudeUsageBreakdown(inputTokens: 50, outputTokens: 1,
										  cacheCreationInputTokens: 0, cacheReadInputTokens: 0)
		_ = ledger.ingest(identity: identity("msg_2", .turnAggregate), scope: .topLevel, breakdown: bigger)
		XCTAssertEqual(ledger.latestContextUsedTokens, 50)
	}

	/// A duplicate must not move the latest-context reading either.
	func testDuplicateDoesNotDisturbLatestContextUsed() {
		var ledger = ClaudeUsageLedger()
		let first = identity("msg_1", .turnAggregate)
		_ = ledger.ingest(identity: first, scope: .topLevel, breakdown: sample)
		let bigger = ClaudeUsageBreakdown(inputTokens: 50, outputTokens: 1,
										  cacheCreationInputTokens: 0, cacheReadInputTokens: 0)
		_ = ledger.ingest(identity: identity("msg_2", .turnAggregate), scope: .topLevel, breakdown: bigger)
		_ = ledger.ingest(identity: first, scope: .topLevel, breakdown: sample)
		XCTAssertEqual(ledger.latestContextUsedTokens, 50, "a replayed older event must not rewind the reading")
	}
}

/// Slice 4a: the normalized lane models usage. Before 4a there was no usage case
/// and no usage field on any case, so the assistant/result `usage` payloads had
/// no normalized representation at all.
final class ClaudeRuntimeEventUsageTests: XCTestCase {
	func testUsageEventCarriesFullBreakdownAndIdentity() {
		let event = ClaudeRuntimeEvent.usage(.init(
			identity: ClaudeUsageIdentity(sessionID: "s1", messageID: "msg_1", phase: .turnAggregate),
			scope: .topLevel,
			breakdown: ClaudeUsageBreakdown(inputTokens: 10, outputTokens: 5,
											cacheCreationInputTokens: 7, cacheReadInputTokens: 100),
			modelContextWindow: 200_000,
			extra: [:]
		))
		guard case .usage(let u) = event else { return XCTFail("expected .usage") }
		XCTAssertEqual(u.breakdown.cacheReadInputTokens, 100)
		XCTAssertEqual(u.breakdown.cacheCreationInputTokens, 7)
		XCTAssertEqual(u.breakdown.contextUsedTokens, 117)
		XCTAssertEqual(u.modelContextWindow, 200_000)
		XCTAssertEqual(u.identity.phase, .turnAggregate)
		XCTAssertEqual(u.scope, .topLevel)
	}

	func testUsageEventIsEquatable() {
		let make = {
			ClaudeRuntimeEvent.usage(.init(
				identity: ClaudeUsageIdentity(sessionID: "s1", messageID: "msg_1", phase: .assistantSnapshot),
				scope: .child(parentMessageID: "msg_0"),
				breakdown: .zero, modelContextWindow: nil, extra: [:]
			))
		}
		XCTAssertEqual(make(), make())
	}
}
