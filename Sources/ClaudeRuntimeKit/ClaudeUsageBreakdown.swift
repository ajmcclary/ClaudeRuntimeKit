import Foundation

/// Cache-aware Claude token breakdown (Slice 4a, ClaudeRuntimeCore).
///
/// The full four-field breakdown lives on the normalized lane only. The
/// provider-neutral `AIStreamResult` continues to carry the pre-summed aggregate
/// (`contextUsedTokens`) and is deliberately NOT widened — widening a shared
/// carrier for one provider's needs would create cross-provider work with no
/// consumer.
public struct ClaudeUsageBreakdown: Equatable, Sendable {
	public let inputTokens: Int
	public let outputTokens: Int
	public let cacheCreationInputTokens: Int
	public let cacheReadInputTokens: Int

	public static let zero = ClaudeUsageBreakdown(
		inputTokens: 0, outputTokens: 0,
		cacheCreationInputTokens: 0, cacheReadInputTokens: 0
	)

	public init(
		inputTokens: Int,
		outputTokens: Int,
		cacheCreationInputTokens: Int,
		cacheReadInputTokens: Int
	) {
		self.inputTokens = max(0, inputTokens)
		self.outputTokens = max(0, outputTokens)
		self.cacheCreationInputTokens = max(0, cacheCreationInputTokens)
		self.cacheReadInputTokens = max(0, cacheReadInputTokens)
	}

	/// Tokens occupying the context window. Mirrors the translator's existing
	/// derivation exactly: input + cache-read + cache-creation, output EXCLUDED.
	/// Changing this changes observable behavior — it is pinned by
	/// `ClaudeUsageAccountingCharacterizationTests.testContextUsedExcludesOutputTokens`.
	public var contextUsedTokens: Int {
		inputTokens + cacheReadInputTokens + cacheCreationInputTokens
	}

	public func adding(_ other: ClaudeUsageBreakdown) -> ClaudeUsageBreakdown {
		ClaudeUsageBreakdown(
			inputTokens: inputTokens + other.inputTokens,
			outputTokens: outputTokens + other.outputTokens,
			cacheCreationInputTokens: cacheCreationInputTokens + other.cacheCreationInputTokens,
			cacheReadInputTokens: cacheReadInputTokens + other.cacheReadInputTokens
		)
	}
}
