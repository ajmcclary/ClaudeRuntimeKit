import Foundation

/// A preserved diagnostic for a Claude stream line that the semantic lane could
/// not fully consume (Program A; ClaudeRuntimeCore).
///
/// Diagnostics are counted by a STABLE `fingerprint` (invariant to variable
/// payload content), redacted by key, and never carry secrets in `summary`.
/// They are diagnostic attachments only — never canonical transcript content
/// and never auto-converted to user-facing errors (controller policy).
public struct ClaudeRuntimeDiagnostic: Sendable {
	public enum Kind: String, Sendable {
		case unknownEvent
		case malformedKnownEvent
		case malformedToolInput
		case malformedLine
	}

	public let kind: Kind
	/// Stable across payloads that differ only in variable content, so counting
	/// groups like events together.
	public let fingerprint: String
	/// Human-readable, redacted-by-construction (derived from identity, never
	/// from payload values).
	public let summary: String
	/// Structurally redacted parsed payload, or nil when there is no JSON object
	/// to redact (malformed line / malformed tool-input buffer).
	private let redactedJSONData: Data?
	public var redactedPayload: [String: Any]? {
		guard let redactedJSONData else { return nil }
		return (try? JSONSerialization.jsonObject(with: redactedJSONData)) as? [String: Any]
	}
	public let rawByteCount: Int

	private init(kind: Kind, fingerprint: String, summary: String, redactedPayload: [String: Any]?, rawByteCount: Int) {
		self.kind = kind
		self.fingerprint = fingerprint
		self.summary = summary
		self.redactedJSONData = redactedPayload.flatMap { try? JSONSerialization.data(withJSONObject: $0) }
		self.rawByteCount = rawByteCount
	}

	// MARK: - Factories

	public static func unknownEvent(from envelope: ClaudeEventEnvelope) -> ClaudeRuntimeDiagnostic {
		let type = envelope.type ?? "<none>"
		let subtype = envelope.subtype ?? "<none>"
		return ClaudeRuntimeDiagnostic(
			kind: .unknownEvent,
			fingerprint: "unknownEvent|type=\(type)|subtype=\(subtype)",
			summary: "Unknown Claude event (type=\(type), subtype=\(subtype))",
			redactedPayload: makeRedactedPayload(from: envelope),
			rawByteCount: envelope.rawBytes.count
		)
	}

	public static func malformedKnownEvent(
		from envelope: ClaudeEventEnvelope,
		detail: String
	) -> ClaudeRuntimeDiagnostic {
		let type = envelope.type ?? "<none>"
		return ClaudeRuntimeDiagnostic(
			kind: .malformedKnownEvent,
			fingerprint: "malformedKnownEvent|type=\(type)|detail=\(detail)",
			summary: "Malformed \(type) event: \(detail)",
			redactedPayload: makeRedactedPayload(from: envelope),
			rawByteCount: envelope.rawBytes.count
		)
	}

	public static func malformedLine(from envelope: ClaudeEventEnvelope) -> ClaudeRuntimeDiagnostic {
		ClaudeRuntimeDiagnostic(
			kind: .malformedLine,
			fingerprint: "malformedLine",
			summary: "Malformed (non-JSON-object) line (\(envelope.rawBytes.count) bytes)",
			redactedPayload: nil,
			rawByteCount: envelope.rawBytes.count
		)
	}

	public static func malformedToolInput(
		messageID: String?,
		blockIndex: Int?,
		rawBuffer: String
	) -> ClaudeRuntimeDiagnostic {
		let byteCount = rawBuffer.utf8.count
		let message = messageID ?? "?"
		let block = blockIndex.map(String.init) ?? "?"
		// The raw buffer is malformed partial JSON and may contain secrets, so it
		// is NEVER placed in the summary or sample — only its size is recorded.
		return ClaudeRuntimeDiagnostic(
			kind: .malformedToolInput,
			fingerprint: "malformedToolInput",
			summary: "Malformed tool input (\(byteCount) bytes, message=\(message), block=\(block))",
			redactedPayload: nil,
			rawByteCount: byteCount
		)
	}

	private static func makeRedactedPayload(from envelope: ClaudeEventEnvelope) -> [String: Any]? {
		guard let json = envelope.json else { return nil }
		return ClaudeCredentialRedactor.redact(json) as? [String: Any]
	}
}

/// Bounded, redacted store of runtime diagnostics owned by the controller.
///
/// Counts are complete (keyed by the coarse, low-cardinality fingerprint);
/// samples are bounded to `maxSamples` distinct fingerprints, first-seen. The
/// store lives outside the transcript/persistence path entirely.
public struct ClaudeRuntimeDiagnosticAccumulator: Sendable {
	public let maxSamples: Int
	public private(set) var totalCount = 0
	public private(set) var countsByFingerprint: [String: Int] = [:]
	public private(set) var samples: [ClaudeRuntimeDiagnostic] = []
	private var sampledFingerprints: Set<String> = []

	public init(maxSamples: Int = 32) {
		self.maxSamples = maxSamples
	}

	public mutating func record(_ diagnostic: ClaudeRuntimeDiagnostic) {
		totalCount += 1
		countsByFingerprint[diagnostic.fingerprint, default: 0] += 1
		guard !sampledFingerprints.contains(diagnostic.fingerprint),
			samples.count < maxSamples else {
			return
		}
		sampledFingerprints.insert(diagnostic.fingerprint)
		samples.append(diagnostic)
	}

	public func count(for fingerprint: String) -> Int {
		countsByFingerprint[fingerprint] ?? 0
	}
}
