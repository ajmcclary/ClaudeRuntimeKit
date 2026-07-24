import Foundation

/// Lossless, per-line decode of a Claude NDJSON stream line (Program A /
/// Slice 1). App-local for now.
///
/// The envelope always preserves the original `rawBytes`. When the line is a
/// JSON object it also exposes the parsed `json` plus stable identity fields
/// used for routing, diagnostics, and (later) semantic normalization. Non-object
/// lines are non-decodable (`json == nil`) but still carry their raw bytes so a
/// malformed-line diagnostic can be produced without dropping evidence.
public struct ClaudeEventEnvelope {
	public let rawBytes: Data
	public let json: [String: Any]?
	public let type: String?
	public let subtype: String?
	public let sessionID: String?
	public let requestID: String?
	public let parentToolUseID: String?
	public let messageID: String?
	public let timestamp: String?
	public let binaryVersion: String?

	public var isDecodable: Bool { json != nil }

	public static func decode(line: Data) -> ClaudeEventEnvelope {
		guard
			let trimmed = trimmedASCIIWhitespace(line),
			!trimmed.isEmpty,
			let object = (try? JSONSerialization.jsonObject(with: trimmed)) as? [String: Any]
		else {
			return ClaudeEventEnvelope(
				rawBytes: line,
				json: nil,
				type: nil,
				subtype: nil,
				sessionID: nil,
				requestID: nil,
				parentToolUseID: nil,
				messageID: nil,
				timestamp: nil,
				binaryVersion: nil
			)
		}

		return ClaudeEventEnvelope(
			rawBytes: line,
			json: object,
			type: firstString(object, ["type"]),
			subtype: firstString(object, ["subtype"]),
			sessionID: firstString(object, ["session_id", "sessionId"]),
			requestID: firstString(object, ["request_id", "requestId"]),
			parentToolUseID: firstString(object, ["parent_tool_use_id", "parentToolUseId", "parentToolUseID"]),
			messageID: messageID(in: object),
			timestamp: timestamp(in: object),
			binaryVersion: firstString(object, ["version", "cli_version", "claude_version", "claudeVersion"])
		)
	}

	// MARK: - Field extraction

	private static func messageID(in object: [String: Any]) -> String? {
		if let message = object["message"] as? [String: Any],
			let nested = firstString(message, ["id", "message_id", "messageId"]) {
			return nested
		}
		return firstString(object, ["uuid", "message_id", "messageId", "id"])
	}

	private static func timestamp(in object: [String: Any]) -> String? {
		for key in ["timestamp", "ts", "time"] {
			if let value = object[key] as? String,
				!value.trimmingCharacters(in: .whitespaces).isEmpty {
				return value
			}
			if let number = object[key] as? NSNumber {
				return number.stringValue
			}
		}
		return nil
	}

	private static func firstString(_ object: [String: Any], _ keys: [String]) -> String? {
		for key in keys {
			if let value = object[key] as? String, !value.isEmpty {
				return value
			}
		}
		return nil
	}

	private static func trimmedASCIIWhitespace(_ data: Data) -> Data? {
		let whitespace: Set<UInt8> = [0x20, 0x09, 0x0A, 0x0D]
		guard let start = data.firstIndex(where: { !whitespace.contains($0) }),
			let end = data.lastIndex(where: { !whitespace.contains($0) })
		else {
			return nil
		}
		return data.subdata(in: start..<(end + 1))
	}
}
