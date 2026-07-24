import Foundation

/// Which fact a usage payload represents. Same message, different phase = a
/// distinct fact, not a duplicate.
public enum ClaudeUsagePhase: String, Equatable, Hashable, Sendable {
	/// Per-assistant-message snapshot (`assistant.message.usage`, `message_start`,
	/// `message_delta`) — a live context reading.
	case assistantSnapshot
	/// The billed-turn aggregate carried on the `result` message.
	case turnAggregate
}

/// Whether a usage payload belongs to the top-level turn or to a subagent.
public enum ClaudeUsageScope: Equatable, Hashable, Sendable {
	case topLevel
	case child(parentMessageID: String?)
}

/// Replay-safe dedup key. Two payloads with equal identity describe the same
/// fact, so ingesting the second is a no-op — this is what makes replay, resume,
/// and duplicate delivery safe.
public struct ClaudeUsageIdentity: Equatable, Hashable, Sendable {
	public let sessionID: String?
	public let messageID: String?
	public let phase: ClaudeUsagePhase
	/// Disambiguates payloads that arrive without a `messageID`. Producers pass a
	/// monotonically increasing per-session counter. When a `messageID` IS present
	/// the ordinal is discarded, so replay stays stable even if the producer's
	/// counter differs between passes.
	public let ordinal: Int?

	public init(sessionID: String?, messageID: String?, phase: ClaudeUsagePhase, ordinal: Int? = nil) {
		self.sessionID = sessionID
		self.messageID = messageID
		self.phase = phase
		self.ordinal = messageID == nil ? ordinal : nil
	}
}
