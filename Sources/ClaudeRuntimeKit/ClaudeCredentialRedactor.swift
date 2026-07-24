import Foundation

/// Structural redaction for Claude runtime diagnostic payloads (Program A;
/// ClaudeRuntimeCore). The Program-B environment-value scrub + run metadata live
/// app-side in `ClaudeCredentialRedactor+Authentication.swift`.
///
/// Redaction is BY NORMALIZED KEY, never by pattern-matching over rendered
/// JSON: a value is replaced with `placeholder` when its key normalizes to a
/// known-sensitive token. Structure (dict/array shape, non-sensitive values)
/// is preserved so a redacted diagnostic remains useful for support.
public enum ClaudeCredentialRedactor {
	public static let placeholder = "<redacted>"

	/// Keys whose normalized form (lowercased, alphanumeric-only) matches
	/// exactly. Bare `token` is here so `token` redacts but `tokens` does not.
	private static let sensitiveExact: Set<String> = [
		"token", "secret", "password", "passwd", "pwd", "authorization",
		"cookie", "credential", "credentials", "bearer", "apikey",
		"accesskey", "secretkey", "privatekey", "sessionkey", "clientsecret",
	]

	/// Compound needles matched as substrings of the normalized key. Chosen to
	/// avoid false positives (e.g. no bare `token`, which would catch `tokens`;
	/// no bare `auth`, which would catch `author`).
	private static let sensitiveSubstrings: [String] = [
		"apikey", "accesstoken", "refreshtoken", "idtoken", "sessiontoken",
		"authtoken", "bearertoken", "clientsecret", "secretkey", "privatekey",
		"accesskey", "password", "authorization",
	]

	public static func isSensitiveKey(_ key: String) -> Bool {
		let normalized = normalize(key)
		guard !normalized.isEmpty else { return false }
		if sensitiveExact.contains(normalized) { return true }
		return sensitiveSubstrings.contains { normalized.contains($0) }
	}

	/// Returns a redacted copy of `value`, recursing into dictionaries and
	/// arrays. Values under sensitive keys become `placeholder`; every other
	/// scalar passes through unchanged.
	public static func redact(_ value: Any) -> Any {
		switch value {
		case let dict as [String: Any]:
			var out: [String: Any] = [:]
			out.reserveCapacity(dict.count)
			for (key, nested) in dict {
				out[key] = isSensitiveKey(key) ? placeholder : redact(nested)
			}
			return out
		case let array as [Any]:
			return array.map { redact($0) }
		default:
			return value
		}
	}

	private static func normalize(_ key: String) -> String {
		let allowed = CharacterSet.alphanumerics
		var result = ""
		for scalar in key.lowercased().unicodeScalars where allowed.contains(scalar) {
			result.unicodeScalars.append(scalar)
		}
		return result
	}
}
