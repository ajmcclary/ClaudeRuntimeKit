import Foundation

/// Canonical normalized Claude runtime event (Slice 2/3, ClaudeRuntimeCore).
/// Richer than the Program G harness semantic trace, which is a projection of
/// this vocabulary. Extension fields are ClaudeJSONValue — never raw provider
/// dictionaries.
///
/// **Invocation identity is STAMPED, never re-derived.** The translator owns the
/// only authoritative `tool_use_id → UUID` correlation map. It resolves the
/// identity once and stamps it onto every event describing that invocation; a
/// consumer may only COPY the stamped value. Deriving an identity downstream —
/// by parsing `toolu_*`, by generating a UUID, or by keeping a second map —
/// would give one invocation two identities, which surfaces to a user as a tool
/// call and its result that cannot be related to each other.
///
/// The type carries `UUID?` rather than `String?` precisely so that
/// re-derivation is unrepresentable: there is no string left to parse.
public enum ClaudeRuntimeEvent: Equatable {
	case systemInit(SystemInit)
	case assistantText(AssistantText)
	case toolUse(ToolUse)
	case result(ResultEvent)
	case usage(UsageEvent)

	// F2.5 coverage closure. Each carries PARSED PROVIDER FACTS — ids, status,
	// message, limits — never the assembled legacy display string. The app-side
	// projection owns every legacy spelling: joined text, `tool_call` vs
	// `tool_use`, the `system`-row families, and routine-event suppression.
	//
	// Grouped rather than flattened so related families read as related, and
	// deliberately NOT a generic `.system(text:)`: that would preserve output
	// while destroying the semantic boundary this lane exists for.
	case task(TaskEvent)
	case tool(ToolEvent)
	case runtime(RuntimeEvent)
	case telemetry(TelemetryEvent)
	case status(StatusEvent)
	case failure(FailureEvent)
	case toolResult(ToolResultEvent)
	case toolProgress(ToolProgressEvent)

	/// F2.5b — the stream_event SUB-FAMILY.
	///
	/// `stream_event` counted as a covered family for three slices while its
	/// boundary branches had no normalized producer at all: the six
	/// deterministic-fake scenarios contain ZERO `message_delta` and ZERO
	/// `message_stop` frames, so no golden ever exercised them. A live 2.1.215
	/// capture found the gap at frame 19, losing four `message_stop` and two
	/// `content` results.
	///
	/// These are stream-scoped facts, distinct from `.assistantText` (the
	/// COMPLETE assistant message) on purpose. Both legitimately describe the
	/// same text: the provider streams deltas and then repeats the whole message.
	/// The results lane emits `content` for both, and that duplicate is real
	/// behavior — collapsing the two into one case would invite a future
	/// "deduplication" that silently drops user-visible output.
	case stream(StreamEvent)

	public struct SystemInit: Equatable {
		public var sessionID: String?
		public var model: String?
		public var permissionMode: String?
		public var tools: [String]
		public var extra: [String: ClaudeJSONValue]
		public init(sessionID: String?, model: String?, permissionMode: String?, tools: [String], extra: [String: ClaudeJSONValue]) {
			self.sessionID = sessionID; self.model = model; self.permissionMode = permissionMode
			self.tools = tools; self.extra = extra
		}
	}
	/// Stream-scoped facts. Parsed values only — no assembled display string, and
	/// no judgement about whether a boundary ends a TURN. Turn completion is the
	/// app's authority via the lifecycle reconciler; a `message_stop` here is a
	/// message boundary the provider reported, nothing more.
	public enum StreamEvent: Equatable {
		/// One `text_delta` chunk. Never merged with its neighbours: the results
		/// lane emits one `content` per chunk, and joining them would change
		/// observable output.
		case contentDelta(
			messageID: String?,
			blockIndex: Int?,
			text: String,
			extra: [String: ClaudeJSONValue]
		)
		/// `message_delta` carrying a stop reason. Distinct from `messageStop`
		/// because the provider sends both and the results lane emits a
		/// `message_stop` for each — the first WITH a stop reason, the second
		/// without. Folding them together loses one result.
		case messageDeltaStop(
			messageID: String?,
			stopReason: String,
			extra: [String: ClaudeJSONValue]
		)
		/// The wire `message_stop` frame.
		case messageStop(
			messageID: String?,
			extra: [String: ClaudeJSONValue]
		)
	}

	public struct AssistantText: Equatable {
		public var messageID: String?
		public var text: String
		public var extra: [String: ClaudeJSONValue]
		public init(messageID: String?, text: String, extra: [String: ClaudeJSONValue]) {
			self.messageID = messageID; self.text = text; self.extra = extra
		}
	}
	public enum ToolUseSource: Equatable { case streamed, complete }
	public struct ToolUse: Equatable {
		public var messageID: String?
		public var blockIndex: Int?
		public var toolID: String?
		/// STAMPED invocation identity — see `ClaudeRuntimeEvent` type note.
		public var invocationID: UUID?
		public var name: String
		/// Assembled tool-input JSON; optional because serialization can fail (matches
		/// the results lane's optional `toolArgs`), keeping projection parity exact.
		public var input: String?
		public var source: ToolUseSource
		public var extra: [String: ClaudeJSONValue]
		public init(messageID: String?, blockIndex: Int?, toolID: String?, invocationID: UUID? = nil, name: String, input: String?, source: ToolUseSource, extra: [String: ClaudeJSONValue]) {
			self.messageID = messageID; self.blockIndex = blockIndex; self.toolID = toolID
			self.invocationID = invocationID
			self.name = name; self.input = input; self.source = source; self.extra = extra
		}
	}
	public struct ResultEvent: Equatable {
		public var sessionID: String?
		public var subtype: String?
		public var isError: Bool
		public var text: String?
		/// Why the turn stopped, verbatim from the provider (`stop_sequence`,
		/// `end_turn`, …), or nil when the frame carries none.
		///
		/// F2.5a. The results lane has always stamped this onto its `message_stop`;
		/// the normalized lane modelled no equivalent, so the projection produced
		/// `stopReason: nil` and the turn's stop reason was lost at the flip. It went
		/// unnoticed because `ComparableResult` did not compare the field — the
		/// comparator was built around the divergence rather than catching it. The
		/// live 2.1.215 unauthenticated capture is the evidence: results lane
		/// `stop_sequence`, projection nil, with counts otherwise equal at 6 vs 6.
		public var stopReason: String?
		public var extra: [String: ClaudeJSONValue]
		public init(
			sessionID: String?,
			subtype: String?,
			isError: Bool,
			text: String?,
			stopReason: String? = nil,
			extra: [String: ClaudeJSONValue]
		) {
			self.sessionID = sessionID; self.subtype = subtype; self.isError = isError
			self.text = text; self.stopReason = stopReason; self.extra = extra
		}
	}
	/// Normalized token accounting (Slice 4a). Carries the FULL cache-aware
	/// breakdown — the provider-neutral `AIStreamResult` deliberately keeps only
	/// the pre-summed aggregate, so this is the only place cache-creation and
	/// cache-read survive as distinct figures.
	public struct UsageEvent: Equatable {
		public var identity: ClaudeUsageIdentity
		public var scope: ClaudeUsageScope
		public var breakdown: ClaudeUsageBreakdown
		public var modelContextWindow: Int?
		/// Billed cost in USD, present only on the turn aggregate. Carried here
		/// rather than dropped so the parity comparison can see it — an uncompared
		/// field is exactly how the Slice 2/3 gate went blind to usage entirely.
		public var costUSD: Double?
		public var extra: [String: ClaudeJSONValue]
		public init(
			identity: ClaudeUsageIdentity,
			scope: ClaudeUsageScope,
			breakdown: ClaudeUsageBreakdown,
			modelContextWindow: Int?,
			costUSD: Double? = nil,
			extra: [String: ClaudeJSONValue]
		) {
			self.identity = identity; self.scope = scope; self.breakdown = breakdown
			self.modelContextWindow = modelContextWindow; self.costUSD = costUSD
			self.extra = extra
		}
	}
	// MARK: - F2.5 payloads

	/// Child / subagent lifecycle.
	public enum TaskEvent: Equatable {
		case started(taskID: String?, description: String?, extra: [String: ClaudeJSONValue])
		case notification(taskID: String?, status: String?, summary: String?, extra: [String: ClaudeJSONValue])
		case progress(taskID: String?, fragments: [String], extra: [String: ClaudeJSONValue])
	}

	public enum ToolEvent: Equatable {
		/// `tool_use_summary`. The provider's summary text, unjoined.
		///
		/// Carries the stamped `invocationID` even though the legacy lane's `system`
		/// row does NOT, so the normalized lane can relate a summary to its
		/// invocation. Suppressing it here to match legacy would discard the fact at
		/// decode time — the same reasoning that keeps the routine rate-limit
		/// "allowed" status in core. The projection declines to copy it.
		case summary(toolUseID: String?, invocationID: UUID?, summary: String, extra: [String: ClaudeJSONValue])
	}

	public enum RuntimeEvent: Equatable {
		/// `session_state_changed`. The state verbatim, lowercased by the reader.
		case sessionStateChanged(state: String, extra: [String: ClaudeJSONValue])
		/// `compact_boundary`.
		case compactBoundary(trigger: String?, preTokens: Int?, extra: [String: ClaudeJSONValue])
	}

	public enum TelemetryEvent: Equatable {
		/// `rate_limit_event`. `status` is carried verbatim INCLUDING the routine
		/// "allowed" case — suppression is a projection decision, not a decoding
		/// one, so the fact is not lost before anyone can see it.
		case rateLimit(
			status: String?,
			rateLimitType: String?,
			overageStatus: String?,
			extra: [String: ClaudeJSONValue]
		)
		/// `auth_status`. The provider emits TWO shapes and both must be modelled:
		/// an `isAuthenticating` progress form carrying output/error lines, and a
		/// bare `status`/`message` form. Modelling only the first would silently
		/// drop every frame of the second — which is the shape the corpus actually
		/// carries.
		case authStatus(
			isAuthenticating: Bool?,
			output: [String],
			error: String?,
			status: String?,
			message: String?,
			extra: [String: ClaudeJSONValue]
		)
	}

	/// `system/status`. Carries the provider's status string VERBATIM.
	///
	/// The legacy lane rewrites the bare status "compacting" into the display
	/// phrase "Compacting context". That substitution is a legacy spelling, so it
	/// lives in the projection — core storing the rewritten phrase would make the
	/// normalized lane unable to tell which status the provider actually sent.
	public struct StatusEvent: Equatable {
		public var status: String?
		public var extra: [String: ClaudeJSONValue]
		public init(status: String?, extra: [String: ClaudeJSONValue]) {
			self.status = status; self.extra = extra
		}
	}

	/// A provider-reported error. Named `failure` because `error` collides with
	/// the Swift error vocabulary at call sites.
	public struct FailureEvent: Equatable {
		public var message: String
		public var extra: [String: ClaudeJSONValue]
		public init(message: String, extra: [String: ClaudeJSONValue]) {
			self.message = message; self.extra = extra
		}
	}

	public struct ToolResultEvent: Equatable {
		public var toolUseID: String?
		public var toolName: String?
		/// STAMPED invocation identity — see `ClaudeRuntimeEvent` type note. This was
		/// a `String?` before F2.5, which the projection fed to `UUID(uuidString:)`;
		/// every real id (`toolu_1`) failed to parse, so the identity was silently
		/// dropped. A `UUID?` makes that mistake unrepresentable.
		public var invocationID: UUID?
		public var output: String?
		public var isError: Bool?
		public var extra: [String: ClaudeJSONValue]
		public init(
			toolUseID: String?, toolName: String?, invocationID: UUID?,
			output: String?, isError: Bool?, extra: [String: ClaudeJSONValue]
		) {
			self.toolUseID = toolUseID; self.toolName = toolName
			self.invocationID = invocationID; self.output = output
			self.isError = isError; self.extra = extra
		}
	}

	public struct ToolProgressEvent: Equatable {
		public var toolUseID: String?
		/// STAMPED invocation identity. As with `.tool(.summary)`, the legacy
		/// `tool_progress` result carries no invocation id; core keeps the fact and
		/// the projection declines to copy it.
		public var invocationID: UUID?
		public var toolName: String?
		public var status: String?
		public var detail: String?
		public var extra: [String: ClaudeJSONValue]
		public init(toolUseID: String? = nil, invocationID: UUID? = nil, toolName: String?, status: String?, detail: String?, extra: [String: ClaudeJSONValue]) {
			self.toolUseID = toolUseID; self.invocationID = invocationID
			self.toolName = toolName; self.status = status
			self.detail = detail; self.extra = extra
		}
	}

}
