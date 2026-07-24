import Foundation

/// A closed JSON value used to retain unconsumed Claude provider fields inside
/// normalized events WITHOUT exposing `[String: Any]` upward (Slice 2 ratchet).
public enum ClaudeJSONValue: Equatable, Sendable {
	case string(String)
	case number(Double)
	case bool(Bool)
	case null
	indirect case array([ClaudeJSONValue])
	indirect case object([String: ClaudeJSONValue])

	public static func from(_ any: Any?) -> ClaudeJSONValue {
		switch any {
		case let s as String: return .string(s)
		case let arr as [Any]: return .array(arr.map { from($0) })
		case let dict as [String: Any]: return .object(dict.mapValues { from($0) })
		case let n as NSNumber:
			// Discriminate booleans explicitly to avoid the NSNumber<->Bool
			// bridging ambiguity (a numeric 1 must stay .number, not .bool).
			if CFGetTypeID(n) == CFBooleanGetTypeID() { return .bool(n.boolValue) }
			return .number(n.doubleValue)
		case let b as Bool: return .bool(b)
		default:
			return .null
		}
	}
}
