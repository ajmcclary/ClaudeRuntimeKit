import Foundation

/// Normalized Claude lifecycle vocabulary (Slice 4b, ClaudeRuntimeCore).
///
/// A lifecycle event describes WHAT ARRIVED on the wire: its phase, its wire
/// identity, and its scope. That is the whole contract.
///
/// Two things are deliberately absent, and both absences are load-bearing:
///
///   - **No app turn ID.** Turn identity is minted by the controller and is not
///     knowable from a Claude payload. A decoder that could name a turn could
///     bind an event to the wrong one.
///   - **No completion authority.** Nothing here says "finish a turn". Whether
///     an observation closes anything is an app-side reconciliation decision.
///
/// The decoder describes. It does not decide.

/// Session run state as reported by `session_state_changed`.
public enum ClaudeLifecycleRunState: Equatable, Sendable {
	case running
	case idle
	/// A state we do not model. Preserved verbatim rather than coerced into a
	/// known case — collapsing an unknown state into `idle` would invent a
	/// completion boundary that the provider never signalled.
	case other(String)
}

/// Wire identity carried by a lifecycle event. Every field is provider-minted.
public struct ClaudeLifecycleIdentity: Equatable, Sendable {
	public var sessionID: String?
	public var messageID: String?
	public var taskID: String?

	public init(sessionID: String?, messageID: String?, taskID: String?) {
		self.sessionID = sessionID
		self.messageID = messageID
		self.taskID = taskID
	}

	public static let empty = ClaudeLifecycleIdentity(sessionID: nil, messageID: nil, taskID: nil)
}

/// Which conversation an event belongs to.
public enum ClaudeLifecycleScope: Equatable, Sendable {
	/// The top-level conversation — the only scope whose events may ever close a
	/// top-level turn.
	case topLevel
	/// A subagent / background task.
	case child
	/// Lifecycle-shaped, but its scope cannot be determined from the wire. The
	/// reconciler must never complete on this scope: resolving the ambiguity by
	/// guessing is precisely the "a child event completed a top-level turn" bug.
	case unresolved
}

public struct ClaudeLifecycleEvent: Equatable, Sendable {
	public enum Phase: Equatable, Sendable {
		case runStateChanged(ClaudeLifecycleRunState)
		case resultObserved
		case childTaskStarted
		case childTaskNotification
		case childTaskProgress
	}

	public var phase: Phase
	public var identity: ClaudeLifecycleIdentity
	public var scope: ClaudeLifecycleScope

	public init(phase: Phase, identity: ClaudeLifecycleIdentity, scope: ClaudeLifecycleScope) {
		self.phase = phase
		self.identity = identity
		self.scope = scope
	}
}

/// The single lifecycle normalizer. Pure, Foundation-only, total: any frame that
/// is not lifecycle-shaped yields `nil` rather than a guess.
///
/// Inputs are primitive wire facts rather than a payload dictionary so that this
/// stays independent of both the app's stream types and any particular JSON
/// shape. R12 ratchets that there is exactly one of these.
public enum ClaudeLifecycleNormalizer {

	public static func lifecycleEvent(
		payloadType: String,
		subtype: String?,
		sessionState: String?,
		identity: ClaudeLifecycleIdentity
	) -> ClaudeLifecycleEvent? {
		let normalizedSubtype = subtype?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()

		if payloadType == "result" {
			// A result annotated with a task id is ambiguous: child result, or
			// top-level result tagged with the task that produced it? Record the
			// ambiguity; do not resolve it here.
			let scope: ClaudeLifecycleScope = identity.taskID == nil ? .topLevel : .unresolved
			return ClaudeLifecycleEvent(phase: .resultObserved, identity: identity, scope: scope)
		}

		guard payloadType == "system", let normalizedSubtype else { return nil }

		switch normalizedSubtype {
		case "session_state_changed":
			guard let state = normalizedRunState(sessionState) else { return nil }
			return ClaudeLifecycleEvent(
				phase: .runStateChanged(state),
				identity: identity,
				scope: identity.taskID == nil ? .topLevel : .child
			)
		case "task_started":
			return childEvent(.childTaskStarted, identity: identity)
		case "task_notification":
			return childEvent(.childTaskNotification, identity: identity)
		case "task_progress":
			return childEvent(.childTaskProgress, identity: identity)
		default:
			return nil
		}
	}

	/// Child scope follows the SUBTYPE, not the presence of a task id — a child
	/// event that omits its id must not be promoted to the top level.
	private static func childEvent(
		_ phase: ClaudeLifecycleEvent.Phase,
		identity: ClaudeLifecycleIdentity
	) -> ClaudeLifecycleEvent {
		ClaudeLifecycleEvent(phase: phase, identity: identity, scope: .child)
	}

	private static func normalizedRunState(_ raw: String?) -> ClaudeLifecycleRunState? {
		guard let trimmed = raw?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased(),
			!trimmed.isEmpty else { return nil }
		switch trimmed {
		case "running": return .running
		case "idle": return .idle
		default: return .other(trimmed)
		}
	}
}
