import Foundation

// Item 1 of the compatibility-admission plan. Pure value + parsing only: the app
// resolves the executable and runs `--version`; everything here is deterministic
// and unit-testable. Mirrors `CodexCliVersion`, which serves the same role for
// the Codex app-server integration.

/// Parsed `claude` semantic version. Accepts either the bare triple ("2.1.216",
/// optionally with a prerelease suffix) or the full `--version` output
/// ("2.1.216 (Claude Code)"). Malformed input parses to nil — callers classify
/// that explicitly, never as a comparison result.
public struct ClaudeCliVersion: Hashable, Comparable, Sendable, CustomStringConvertible {
	public let major: Int
	public let minor: Int
	public let patch: Int
	public let prerelease: String?

	/// Known-valid construction. Callers must have already validated every
	/// invariant `comparePrerelease` relies on.
	private init(validated major: Int, _ minor: Int, _ patch: Int, _ prerelease: String?) {
		self.major = major
		self.minor = minor
		self.patch = patch
		self.prerelease = prerelease
	}

	/// Validating construction. Fails when any SemVer invariant is violated, so
	/// no `ClaudeCliVersion` can exist that `comparePrerelease` would misorder.
	public init?(major: Int, minor: Int, patch: Int, prerelease: String? = nil) {
		guard major >= 0, minor >= 0, patch >= 0 else { return nil }
		if let prerelease, !Self.isValidPrereleaseString(prerelease[...]) { return nil }
		self.init(validated: major, minor, patch, prerelease)
	}

	/// The exact product suffix emitted by `claude --version`. Only this literal is
	/// stripped: accepting any parenthesised text would let a different CLI's
	/// version output parse as a Claude version.
	static let productSuffix = " (Claude Code)"

	public static func parse(_ raw: String) -> ClaudeCliVersion? {
		var candidate = raw.trimmingCharacters(in: .whitespacesAndNewlines)
		if candidate.hasSuffix(productSuffix) {
			candidate = String(candidate.dropLast(productSuffix.count))
				.trimmingCharacters(in: .whitespacesAndNewlines)
		}
		// Structural validation, not one regex: SemVer forbids empty identifiers
		// and leading-zero numeric identifiers, neither of which a permissive
		// character class rejects.
		let split = candidate.split(separator: "-", maxSplits: 1, omittingEmptySubsequences: false)
		guard let core = split.first else { return nil }
		let prereleaseRaw: Substring? = split.count > 1 ? split[1] : nil

		let coreFields = core.split(separator: ".", omittingEmptySubsequences: false)
		guard coreFields.count == 3 else { return nil }
		var numbers: [Int] = []
		for field in coreFields {
			guard isValidNumericIdentifier(field), let value = Int(field) else { return nil }
			numbers.append(value)
		}

		var prerelease: String?
		if let prereleaseRaw {
			guard isValidPrereleaseString(prereleaseRaw) else { return nil }
			prerelease = String(prereleaseRaw)
		}

		return ClaudeCliVersion(validated: numbers[0], numbers[1], numbers[2], prerelease)
	}

	// MARK: - SemVer identifier validity

	/// ASCII digits only. `Character.isNumber` alone would admit non-ASCII digits.
	static func isAllASCIIDigits(_ s: Substring) -> Bool {
		!s.isEmpty && s.allSatisfy { $0.isASCII && $0.isNumber }
	}

	/// A numeric identifier: digits, with no leading zero unless it is exactly "0".
	static func isValidNumericIdentifier(_ s: Substring) -> Bool {
		isAllASCIIDigits(s) && (s.count == 1 || s.first != "0")
	}

	/// A whole dot-separated prerelease string. The single validity gate shared by
	/// `parse` and the public initializer, so neither can admit a value the other
	/// would reject.
	static func isValidPrereleaseString(_ s: Substring) -> Bool {
		let identifiers = s.split(separator: ".", omittingEmptySubsequences: false)
		return !identifiers.isEmpty && identifiers.allSatisfy(isValidPrereleaseIdentifier)
	}

	/// A prerelease identifier: non-empty, `[0-9A-Za-z-]`, and — when all-numeric —
	/// free of leading zeroes.
	static func isValidPrereleaseIdentifier(_ s: Substring) -> Bool {
		guard !s.isEmpty,
			  s.allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "-") })
		else { return false }
		if isAllASCIIDigits(s) { return isValidNumericIdentifier(s) }
		return true
	}

	public static func < (lhs: ClaudeCliVersion, rhs: ClaudeCliVersion) -> Bool {
		if lhs.major != rhs.major { return lhs.major < rhs.major }
		if lhs.minor != rhs.minor { return lhs.minor < rhs.minor }
		if lhs.patch != rhs.patch { return lhs.patch < rhs.patch }
		// A prerelease precedes its release at the same triple.
		switch (lhs.prerelease, rhs.prerelease) {
		case (nil, nil): return false
		case (.some, nil): return true
		case (nil, .some): return false
		case (.some(let left), .some(let right)):
			return comparePrerelease(left, right) < 0
		}
	}

	/// SemVer §11 prerelease precedence. Returns -1, 0, or 1.
	///
	/// Identifiers are compared left to right: all-numeric identifiers compare
	/// numerically (so `beta.2` precedes `beta.10`, which a lexical comparison
	/// gets backwards), numeric identifiers rank below alphanumeric ones, and
	/// when every shared identifier is equal the longer field set wins.
	static func comparePrerelease(_ lhs: String, _ rhs: String) -> Int {
		let left = lhs.split(separator: ".", omittingEmptySubsequences: false)
		let right = rhs.split(separator: ".", omittingEmptySubsequences: false)
		for index in 0..<max(left.count, right.count) {
			// A larger set of fields has higher precedence when all preceding are equal.
			if index >= left.count { return -1 }
			if index >= right.count { return 1 }
			let a = left[index], b = right[index]
			// Digit detection, never Int conversion: SemVer numeric identifiers are
			// unbounded, and an overflowing one would be misclassified as
			// alphanumeric. Both are validated leading-zero-free at parse time, so
			// digit count orders magnitude and equal lengths compare bytewise.
			switch (isAllASCIIDigits(a), isAllASCIIDigits(b)) {
			case (true, true):
				if a.count != b.count { return a.count < b.count ? -1 : 1 }
				if a != b { return a < b ? -1 : 1 }
			case (true, false):
				return -1
			case (false, true):
				return 1
			case (false, false):
				if a != b { return a < b ? -1 : 1 }
			}
		}
		return 0
	}

	public var description: String {
		let triple = "\(major).\(minor).\(patch)"
		guard let prerelease else { return triple }
		return "\(triple)-\(prerelease)"
	}
}
