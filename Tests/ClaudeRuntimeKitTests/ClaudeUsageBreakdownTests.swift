import XCTest
@testable import ClaudeRuntimeKit

final class ClaudeUsageBreakdownTests: XCTestCase {
	func testContextUsedSumsInputAndBothCacheFieldsExcludingOutput() {
		let breakdown = ClaudeUsageBreakdown(
			inputTokens: 10, outputTokens: 5,
			cacheCreationInputTokens: 7, cacheReadInputTokens: 100
		)
		XCTAssertEqual(breakdown.contextUsedTokens, 117)
	}

	func testNegativeInputsClampToZero() {
		let breakdown = ClaudeUsageBreakdown(
			inputTokens: -10, outputTokens: -5,
			cacheCreationInputTokens: -7, cacheReadInputTokens: -100
		)
		XCTAssertEqual(breakdown.inputTokens, 0)
		XCTAssertEqual(breakdown.outputTokens, 0)
		XCTAssertEqual(breakdown.cacheCreationInputTokens, 0)
		XCTAssertEqual(breakdown.cacheReadInputTokens, 0)
		XCTAssertEqual(breakdown.contextUsedTokens, 0)
	}

	func testAdditionIsComponentwise() {
		let a = ClaudeUsageBreakdown(inputTokens: 1, outputTokens: 2,
									 cacheCreationInputTokens: 3, cacheReadInputTokens: 4)
		let b = ClaudeUsageBreakdown(inputTokens: 10, outputTokens: 20,
									 cacheCreationInputTokens: 30, cacheReadInputTokens: 40)
		let sum = a.adding(b)
		XCTAssertEqual(sum.inputTokens, 11)
		XCTAssertEqual(sum.outputTokens, 22)
		XCTAssertEqual(sum.cacheCreationInputTokens, 33)
		XCTAssertEqual(sum.cacheReadInputTokens, 44)
	}

	func testZeroIsAdditiveIdentity() {
		let a = ClaudeUsageBreakdown(inputTokens: 1, outputTokens: 2,
									 cacheCreationInputTokens: 3, cacheReadInputTokens: 4)
		XCTAssertEqual(a.adding(.zero), a)
		XCTAssertEqual(ClaudeUsageBreakdown.zero.adding(a), a)
	}

	/// Matches the translator's existing derivation: a payload carrying only
	/// cache-read still reports context usage.
	func testCacheReadAloneCountsTowardContext() {
		let breakdown = ClaudeUsageBreakdown(
			inputTokens: 0, outputTokens: 0,
			cacheCreationInputTokens: 0, cacheReadInputTokens: 100
		)
		XCTAssertEqual(breakdown.contextUsedTokens, 100)
	}
}
