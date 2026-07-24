import Foundation

// Item 5 of the compatibility-admission plan: the strict manifest value types and
// the fail-closed decoder, living in the pure core.
//
// The decoder is the runtime's second line of defence after item 3's build-time
// resource gate. It takes `Data` and never touches `Bundle`/`FileManager`: the
// app-side loader owns resource layout, the core owns decoding rules. Everything
// here is a value with a bounded vocabulary — an invalid hash, an out-of-set enum,
// an inverted version range, or a known-bad rule with the wrong number of match
// axes is REJECTED with a specific reason, never coerced.

// MARK: - Bounded manifest vocabularies

public enum ClaudeFamilyClassification: String, Hashable, Sendable, CaseIterable {
	case supported
	case limited
	case externalOnly = "external-only"
}

public enum ClaudeCapabilityState: String, Hashable, Sendable, CaseIterable {
	case certified
	case uncertified
}

/// The one certification method left standing after the item-2 spike. Idle-ack and
/// captured-receipt were eliminated; the schema pins this to a single value and the
/// decoder rejects anything else.
public enum ClaudeInterruptMethod: String, Hashable, Sendable, CaseIterable {
	case inFlightCanary = "in-flight-canary"
}

/// The two abort frame fields the canary actually observed. There is deliberately
/// no `result.aborted` case — that field does not exist, and a check against it
/// could never fire.
public enum ClaudeAbortSignal: String, Hashable, Sendable, CaseIterable {
	case assistantAborted = "assistant.aborted==true"
	case resultTerminalReasonAbortedStreaming = "result.terminal_reason==aborted_streaming"
}

// MARK: - Capability records

public struct ClaudeCapabilityEvidence: Hashable, Sendable {
	public let state: ClaudeCapabilityState
	public let evidence: String

	public init(state: ClaudeCapabilityState, evidence: String) {
		self.state = state
		self.evidence = evidence
	}
}

public struct ClaudeInterruptCapability: Hashable, Sendable {
	public let state: ClaudeCapabilityState
	public let method: ClaudeInterruptMethod
	public let abortSignals: Set<ClaudeAbortSignal>
	public let evidence: String

	public init(state: ClaudeCapabilityState, method: ClaudeInterruptMethod,
				abortSignals: Set<ClaudeAbortSignal>, evidence: String) {
		self.state = state
		self.method = method
		self.abortSignals = abortSignals
		self.evidence = evidence
	}
}

public struct ClaudeFamilyCapabilities: Hashable, Sendable {
	public let models: [String]
	public let effortLevels: [String]
	public let structuredOutput: ClaudeCapabilityEvidence
	public let resume: ClaudeCapabilityEvidence
	public let interrupt: ClaudeInterruptCapability
	public let permissionModeRoundTrip: Bool

	public init(models: [String], effortLevels: [String],
				structuredOutput: ClaudeCapabilityEvidence, resume: ClaudeCapabilityEvidence,
				interrupt: ClaudeInterruptCapability, permissionModeRoundTrip: Bool) {
		self.models = models
		self.effortLevels = effortLevels
		self.structuredOutput = structuredOutput
		self.resume = resume
		self.interrupt = interrupt
		self.permissionModeRoundTrip = permissionModeRoundTrip
	}
}

// MARK: - Family and identity

public struct ClaudeCliVersionRange: Hashable, Sendable {
	public let min: ClaudeCliVersion
	public let max: ClaudeCliVersion

	public init(min: ClaudeCliVersion, max: ClaudeCliVersion) {
		self.min = min
		self.max = max
	}
}

public struct ClaudeCertifiedIdentity: Hashable, Sendable {
	public let sha256: ClaudeSHA256
	/// Typed (P2): distinct from a behaviour key, so the two axes cannot be swapped.
	public let launchProfileKey: ClaudeLaunchProfileKey
	public let signingClass: ClaudeExecutableSigningClass

	public init(sha256: ClaudeSHA256, launchProfileKey: ClaudeLaunchProfileKey,
				signingClass: ClaudeExecutableSigningClass) {
		self.sha256 = sha256
		self.launchProfileKey = launchProfileKey
		self.signingClass = signingClass
	}
}

public struct ClaudeManifestFamily: Hashable, Sendable {
	/// Typed (P2).
	public let behaviorKey: ClaudeBehaviorKey
	public let cliVersionRange: ClaudeCliVersionRange
	public let certifiedIdentities: [ClaudeCertifiedIdentity]
	public let classification: ClaudeFamilyClassification
	public let capabilities: ClaudeFamilyCapabilities
	public let limitations: [String]
	public let evidence: [String]

	public init(behaviorKey: ClaudeBehaviorKey, cliVersionRange: ClaudeCliVersionRange,
				certifiedIdentities: [ClaudeCertifiedIdentity],
				classification: ClaudeFamilyClassification,
				capabilities: ClaudeFamilyCapabilities,
				limitations: [String], evidence: [String]) {
		self.behaviorKey = behaviorKey
		self.cliVersionRange = cliVersionRange
		self.certifiedIdentities = certifiedIdentities
		self.classification = classification
		self.capabilities = capabilities
		self.limitations = limitations
		self.evidence = evidence
	}
}

/// A known-bad rule matches on EXACTLY one axis. Modelling it as an enum makes the
/// "exactly one" invariant unrepresentable-otherwise: there is no way to hold two
/// axes or none at once.
public enum ClaudeKnownBadMatch: Hashable, Sendable {
	case sha256(ClaudeSHA256)
	/// Typed (P2): each axis is its own key type, so a rule authored for one axis
	/// cannot be compared against another.
	case behaviorKey(ClaudeBehaviorKey)
	case certificationKey(ClaudeCertificationKey)
}

public struct ClaudeKnownBadRule: Hashable, Sendable {
	public let match: ClaudeKnownBadMatch
	public let reason: String

	public init(match: ClaudeKnownBadMatch, reason: String) {
		self.match = match
		self.reason = reason
	}
}

public struct ClaudeCompatibilityManifest: Hashable, Sendable {
	public let schemaVersion: Int
	public let manifestVersion: String
	public let families: [ClaudeManifestFamily]
	public let knownBadRules: [ClaudeKnownBadRule]

	public init(schemaVersion: Int, manifestVersion: String,
				families: [ClaudeManifestFamily], knownBadRules: [ClaudeKnownBadRule]) {
		self.schemaVersion = schemaVersion
		self.manifestVersion = manifestVersion
		self.families = families
		self.knownBadRules = knownBadRules
	}

	/// The conservative stand-in for an ABSENT manifest (§10.1): no families and no
	/// known-bad rules. The coordinator turns this into `untested` for every
	/// identity — enforcement stays ON and falls conservative; it is never
	/// "enforcement disabled".
	public static let empty = ClaudeCompatibilityManifest(
		schemaVersion: 1, manifestVersion: "", families: [], knownBadRules: [])
}

// MARK: - Decoding errors

public enum ClaudeManifestDecodingError: Error, Equatable {
	case notAnObject
	case missingKey(String)
	case wrongType(field: String)
	/// An object carried a property outside its schema allow-list
	/// (`additionalProperties: false`).
	case unexpectedProperty(object: String, property: String)
	case unexpectedSchemaVersion(Int)
	case malformedManifestVersion(String)
	case invalidHash(field: String)
	case invalidEnum(field: String, value: String)
	case malformedVersion(String)
	case invertedVersionRange
	/// A `minItems: 1` array was empty (`families`, `certifiedIdentities`).
	case emptyArray(field: String)
	/// A `minLength: 1` string was empty (`limitations`/`evidence` items, interrupt
	/// `evidence`).
	case emptyString(field: String)
	/// `abortSignals` did not carry exactly two distinct signals.
	case invalidAbortSignalCardinality(Int)
	/// A known-bad `match` object carried a number of recognised axes other than
	/// exactly one.
	case knownBadMatchAxisCount(Int)
	/// The same `(sha256, launchProfileKey)` appeared in more than one certified
	/// identity across the manifest. Exact-identity binding requires this pair to be
	/// globally unique, or admission would depend on family order.
	case duplicateCertifiedIdentity
}

// MARK: - Fail-closed decoder

public extension ClaudeCompatibilityManifest {
	/// Decode from bytes, rejecting every shape the v1 JSON Schema rejects. This is
	/// an INDEPENDENT gate, not a subset of the schema: unknown properties,
	/// cardinality, patterns, constants, uniqueness, and non-empty-evidence
	/// constraints all fail here too. A packaged `families: []` resource FAILS — only
	/// the application constructs a conservative fallback (`.empty`), never the
	/// decoder.
	static func decode(from data: Data) throws -> ClaudeCompatibilityManifest {
		let parsed: Any
		do {
			parsed = try JSONSerialization.jsonObject(with: data, options: [])
		} catch {
			throw ClaudeManifestDecodingError.notAnObject
		}
		guard let root = parsed as? [String: Any] else {
			throw ClaudeManifestDecodingError.notAnObject
		}
		try Decode.requireOnlyKeys(root, allowed: ["schemaVersion", "manifestVersion",
			"families", "knownBadRules"], object: "manifest")

		let schemaVersion = try Decode.int(root, "schemaVersion")
		guard schemaVersion == 1 else {
			throw ClaudeManifestDecodingError.unexpectedSchemaVersion(schemaVersion)
		}
		let manifestVersion = try Decode.string(root, "manifestVersion")
		guard Decode.isDateOrdinal(manifestVersion) else {
			throw ClaudeManifestDecodingError.malformedManifestVersion(manifestVersion)
		}

		let familyValues = try Decode.array(root, "families")
		guard !familyValues.isEmpty else {
			throw ClaudeManifestDecodingError.emptyArray(field: "families")
		}
		let families = try familyValues.map(decodeFamily)
		try requireUniqueCertifiedIdentities(families)
		let knownBadRules = try Decode.array(root, "knownBadRules").map(decodeKnownBadRule)

		return ClaudeCompatibilityManifest(
			schemaVersion: schemaVersion,
			manifestVersion: manifestVersion,
			families: families,
			knownBadRules: knownBadRules)
	}

	private static func decodeFamily(_ raw: Any) throws -> ClaudeManifestFamily {
		let object = try Decode.asObject(raw, field: "families[]")
		try Decode.requireOnlyKeys(object, allowed: ["behaviorKey", "cliVersionRange",
			"certifiedIdentities", "classification", "capabilities", "limitations",
			"evidence"], object: "family")

		let behaviorKey = ClaudeBehaviorKey(digest: try Decode.hash(object, "behaviorKey"))
		let range = try decodeVersionRange(Decode.object(object, "cliVersionRange"))

		let identityValues = try Decode.array(object, "certifiedIdentities")
		guard !identityValues.isEmpty else {
			throw ClaudeManifestDecodingError.emptyArray(field: "certifiedIdentities")
		}
		let identities = try identityValues.map(decodeIdentity)

		let classification: ClaudeFamilyClassification = try Decode.enumValue(object, "classification")
		let capabilities = try decodeCapabilities(Decode.object(object, "capabilities"))
		let limitations = try Decode.nonEmptyStringArray(object, "limitations")
		let evidence = try Decode.nonEmptyStringArray(object, "evidence")

		return ClaudeManifestFamily(
			behaviorKey: behaviorKey, cliVersionRange: range,
			certifiedIdentities: identities, classification: classification,
			capabilities: capabilities, limitations: limitations, evidence: evidence)
	}

	private static func decodeVersionRange(_ object: [String: Any]) throws -> ClaudeCliVersionRange {
		try Decode.requireOnlyKeys(object, allowed: ["min", "max"], object: "cliVersionRange")
		let min = try decodeExactVersion(object, "min")
		let max = try decodeExactVersion(object, "max")
		guard min <= max else { throw ClaudeManifestDecodingError.invertedVersionRange }
		return ClaudeCliVersionRange(min: min, max: max)
	}

	/// The schema's `exactVersion` is a bare `major.minor.patch` triple — a
	/// prerelease suffix is invalid even though `ClaudeCliVersion.parse` would accept
	/// one. Validate the raw string against the triple shape BEFORE parsing.
	private static func decodeExactVersion(_ object: [String: Any], _ key: String) throws -> ClaudeCliVersion {
		let raw = try Decode.string(object, key)
		guard Decode.isBareTriple(raw), let version = ClaudeCliVersion.parse(raw) else {
			throw ClaudeManifestDecodingError.malformedVersion(raw)
		}
		return version
	}

	private static func decodeIdentity(_ raw: Any) throws -> ClaudeCertifiedIdentity {
		let object = try Decode.asObject(raw, field: "certifiedIdentities[]")
		try Decode.requireOnlyKeys(object, allowed: ["sha256", "launchProfileKey",
			"signingClass"], object: "certifiedIdentity")
		return ClaudeCertifiedIdentity(
			sha256: try Decode.hash(object, "sha256"),
			launchProfileKey: ClaudeLaunchProfileKey(digest: try Decode.hash(object, "launchProfileKey")),
			signingClass: try Decode.enumValue(object, "signingClass"))
	}

	/// Exact-identity binding requires `(sha256, launchProfileKey)` to be globally
	/// unique; otherwise the coordinator's family match would depend on family order.
	/// A packaged manifest violating this fails to decode (→ conservative fallback).
	private static func requireUniqueCertifiedIdentities(_ families: [ClaudeManifestFamily]) throws {
		var seen: Set<String> = []
		for family in families {
			for identity in family.certifiedIdentities {
				let key = identity.sha256.value + "|" + identity.launchProfileKey.digest.value
				guard seen.insert(key).inserted else {
					throw ClaudeManifestDecodingError.duplicateCertifiedIdentity
				}
			}
		}
	}

	private static func decodeCapabilities(_ object: [String: Any]) throws -> ClaudeFamilyCapabilities {
		try Decode.requireOnlyKeys(object, allowed: ["models", "effortLevels",
			"structuredOutput", "resume", "interrupt", "permissionModeRoundTrip"],
			object: "capabilities")
		return ClaudeFamilyCapabilities(
			models: try Decode.stringArray(object, "models"),
			effortLevels: try Decode.stringArray(object, "effortLevels"),
			structuredOutput: try decodeCapabilityEvidence(Decode.object(object, "structuredOutput")),
			resume: try decodeCapabilityEvidence(Decode.object(object, "resume")),
			interrupt: try decodeInterrupt(Decode.object(object, "interrupt")),
			permissionModeRoundTrip: try Decode.bool(object, "permissionModeRoundTrip"))
	}

	private static func decodeCapabilityEvidence(_ object: [String: Any]) throws -> ClaudeCapabilityEvidence {
		try Decode.requireOnlyKeys(object, allowed: ["state", "evidence"], object: "certifiedCapability")
		// The schema puts no minLength on a certifiedCapability's evidence, so an
		// empty string is valid here (unlike interrupt evidence below).
		return ClaudeCapabilityEvidence(
			state: try Decode.enumValue(object, "state"),
			evidence: try Decode.string(object, "evidence"))
	}

	private static func decodeInterrupt(_ object: [String: Any]) throws -> ClaudeInterruptCapability {
		try Decode.requireOnlyKeys(object, allowed: ["state", "method", "abortSignals",
			"evidence"], object: "interruptCapability")
		let signalStrings = try Decode.stringArray(object, "abortSignals")
		var signals: Set<ClaudeAbortSignal> = []
		for raw in signalStrings {
			guard let signal = ClaudeAbortSignal(rawValue: raw) else {
				throw ClaudeManifestDecodingError.invalidEnum(field: "abortSignals", value: raw)
			}
			signals.insert(signal)
		}
		// uniqueItems + minItems 2 + maxItems 2. The RAW array length must be 2 as
		// well as the deduplicated set, or a 3-element array carrying a duplicate of a
		// valid signal would slip past a set-count-only check (maxItems violation).
		// Report the raw length when the array size is wrong, and the distinct count
		// when the array is length 2 but not unique.
		guard signalStrings.count == 2, signals.count == 2 else {
			let reported = signalStrings.count == 2 ? signals.count : signalStrings.count
			throw ClaudeManifestDecodingError.invalidAbortSignalCardinality(reported)
		}
		let evidence = try Decode.string(object, "evidence")
		guard !evidence.isEmpty else {
			throw ClaudeManifestDecodingError.emptyString(field: "evidence")
		}
		return ClaudeInterruptCapability(
			state: try Decode.enumValue(object, "state"),
			method: try Decode.enumValue(object, "method"),
			abortSignals: signals,
			evidence: evidence)
	}

	private static func decodeKnownBadRule(_ raw: Any) throws -> ClaudeKnownBadRule {
		let object = try Decode.asObject(raw, field: "knownBadRules[]")
		try Decode.requireOnlyKeys(object, allowed: ["match", "reason"], object: "knownBadRule")
		let match = try Decode.object(object, "match")
		try Decode.requireOnlyKeys(match, allowed: ["sha256", "behaviorKey",
			"certificationKey"], object: "knownBadRule.match")
		var axes: [ClaudeKnownBadMatch] = []
		if match["sha256"] != nil {
			axes.append(.sha256(try Decode.hash(match, "sha256")))
		}
		if match["behaviorKey"] != nil {
			axes.append(.behaviorKey(ClaudeBehaviorKey(digest: try Decode.hash(match, "behaviorKey"))))
		}
		if match["certificationKey"] != nil {
			axes.append(.certificationKey(ClaudeCertificationKey(digest: try Decode.hash(match, "certificationKey"))))
		}
		guard axes.count == 1 else {
			throw ClaudeManifestDecodingError.knownBadMatchAxisCount(axes.count)
		}
		let reason = try Decode.string(object, "reason")
		guard !reason.isEmpty else { throw ClaudeManifestDecodingError.emptyString(field: "reason") }
		return ClaudeKnownBadRule(match: axes[0], reason: reason)
	}
}

// MARK: - Typed accessors with specific failures

private enum Decode {
	/// Reject any property outside the schema allow-list (`additionalProperties:
	/// false`). Named so the failure points at the offending object AND key.
	static func requireOnlyKeys(_ dict: [String: Any], allowed: Set<String>,
								object: String) throws {
		for key in dict.keys where !allowed.contains(key) {
			throw ClaudeManifestDecodingError.unexpectedProperty(object: object, property: key)
		}
	}

	static func asObject(_ raw: Any, field: String) throws -> [String: Any] {
		guard let object = raw as? [String: Any] else {
			throw ClaudeManifestDecodingError.wrongType(field: field)
		}
		return object
	}

	static func object(_ dict: [String: Any], _ key: String) throws -> [String: Any] {
		guard let value = dict[key] else { throw ClaudeManifestDecodingError.missingKey(key) }
		guard let object = value as? [String: Any] else {
			throw ClaudeManifestDecodingError.wrongType(field: key)
		}
		return object
	}

	static func array(_ dict: [String: Any], _ key: String) throws -> [Any] {
		guard let value = dict[key] else { throw ClaudeManifestDecodingError.missingKey(key) }
		guard let array = value as? [Any] else {
			throw ClaudeManifestDecodingError.wrongType(field: key)
		}
		return array
	}

	static func stringArray(_ dict: [String: Any], _ key: String) throws -> [String] {
		try array(dict, key).map { element in
			guard let string = element as? String else {
				throw ClaudeManifestDecodingError.wrongType(field: key)
			}
			return string
		}
	}

	/// A string array whose items each carry `minLength: 1` (schema `limitations`,
	/// `evidence`). The array itself may be empty; an empty ITEM is rejected.
	static func nonEmptyStringArray(_ dict: [String: Any], _ key: String) throws -> [String] {
		let values = try stringArray(dict, key)
		for value in values where value.isEmpty {
			throw ClaudeManifestDecodingError.emptyString(field: key)
		}
		return values
	}

	static func string(_ dict: [String: Any], _ key: String) throws -> String {
		guard let value = dict[key] else { throw ClaudeManifestDecodingError.missingKey(key) }
		guard let string = value as? String else {
			throw ClaudeManifestDecodingError.wrongType(field: key)
		}
		return string
	}

	static func bool(_ dict: [String: Any], _ key: String) throws -> Bool {
		guard let value = dict[key] else { throw ClaudeManifestDecodingError.missingKey(key) }
		// JSONSerialization surfaces booleans as NSNumber; guard against a numeric
		// masquerading as a bool by requiring the CFBoolean type.
		guard let number = value as? NSNumber,
			  CFGetTypeID(number) == CFBooleanGetTypeID() else {
			throw ClaudeManifestDecodingError.wrongType(field: key)
		}
		return number.boolValue
	}

	/// A strict integer, aligned to the AUTHORITATIVE build-time validator. The
	/// committed complete-inline Python validator types `integer` as
	/// `isinstance(v, int) and not isinstance(v, bool)`, and Python decodes `1.0` as a
	/// `float`, so the build gate REJECTS `1.0`. To keep the two gates in parity, this
	/// decoder rejects any float-typed number too — `1.0`, `1.5`, and `1e309` all
	/// fail; only an integer-typed JSON number is accepted. (`NSNumber.intValue` would
	/// otherwise silently truncate `1.5 → 1` and pass a subsequent `== 1` check.)
	static func int(_ dict: [String: Any], _ key: String) throws -> Int {
		guard let value = dict[key] else { throw ClaudeManifestDecodingError.missingKey(key) }
		guard let number = value as? NSNumber,
			  CFGetTypeID(number) != CFBooleanGetTypeID(),
			  !CFNumberIsFloatType(number) else {
			throw ClaudeManifestDecodingError.wrongType(field: key)
		}
		return number.intValue
	}

	static func hash(_ dict: [String: Any], _ key: String) throws -> ClaudeSHA256 {
		let raw = try string(dict, key)
		guard let sha = ClaudeSHA256(raw) else {
			throw ClaudeManifestDecodingError.invalidHash(field: key)
		}
		return sha
	}

	static func enumValue<T: RawRepresentable>(_ dict: [String: Any], _ key: String) throws -> T
	where T.RawValue == String {
		let raw = try string(dict, key)
		guard let value = T(rawValue: raw) else {
			throw ClaudeManifestDecodingError.invalidEnum(field: key, value: raw)
		}
		return value
	}

	// MARK: Pattern validators (structural, not regex — keeps the core dependency-free)

	/// `^[0-9]{4}-[0-9]{2}-[0-9]{2}\.[0-9]+$` — a date ordinal, never a timestamp.
	static func isDateOrdinal(_ s: String) -> Bool {
		let halves = s.split(separator: ".", omittingEmptySubsequences: false)
		guard halves.count == 2, isAllDigits(halves[1]) else { return false }
		let date = halves[0].split(separator: "-", omittingEmptySubsequences: false)
		guard date.count == 3 else { return false }
		let lengths = [4, 2, 2]
		for (part, length) in zip(date, lengths) where part.count != length || !isAllDigits(part) {
			return false
		}
		return true
	}

	/// `^[0-9]+\.[0-9]+\.[0-9]+$` — a bare version triple, no prerelease.
	static func isBareTriple(_ s: String) -> Bool {
		let parts = s.split(separator: ".", omittingEmptySubsequences: false)
		return parts.count == 3 && parts.allSatisfy(isAllDigits)
	}

	private static func isAllDigits(_ s: Substring) -> Bool {
		!s.isEmpty && s.allSatisfy { $0.isASCII && $0.isNumber }
	}
}
