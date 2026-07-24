import CryptoKit
import Foundation

// MARK: - Bounded launch-profile vocabularies

public enum ClaudeCommandNameClass: String, Hashable, Sendable, CaseIterable {
	case defaultCommand, explicitPath, custom
}

public enum ClaudeModelRoute: String, Hashable, Sendable, CaseIterable {
	case defaultRoute, pinnedModel, conservativeFallback
}

public enum ClaudeEffortClass: String, Hashable, Sendable, CaseIterable {
	case defaultEffort, reduced, elevated
}

public enum ClaudePermissionModeClass: String, Hashable, Sendable, CaseIterable {
	case requireApproval, acceptEdits, bypassPermissions, plan
}

/// Which backend contract the runtime speaks. GLM/Z.ai and a custom
/// OpenAI-compatible endpoint are DIFFERENT contracts: evidence gathered under
/// one must never certify the other.
public enum ClaudeBackendClass: String, Hashable, Sendable, CaseIterable {
	case standardClaude
	case glmZAI
	case customCompatible
}

/// How the runtime authenticates. These are materially different runtime
/// contracts — different credential handling, endpoints, and failure modes — so
/// each gets its own key. Merging any two would let evidence cross a boundary it
/// was never gathered across.
public enum ClaudeAuthenticationModeClass: String, Hashable, Sendable, CaseIterable {
	case anthropicAPIKey
	case bedrock
	case vertexAI
	case foundry
	case enterpriseGateway
	case compatibleBackendCredential
	/// The user drives an external Claude Code CLI that owns its own session.
	case userManagedSubscription
}

/// Domain-separated digest over the sorted disallowed-tool names.
///
/// The launch profile accepts ONLY this wrapper, never a raw `Set<String>`, so
/// the claim that no high-cardinality value can reach the key is structural
/// rather than a review rule: tool names are collapsed to a fixed-width digest
/// before they get anywhere near the launch-profile bytes.
public struct ClaudeDisallowedToolsDigest: Hashable, Sendable {
	public let digest: ClaudeSHA256

	public init(toolNames: Set<String>) {
		self.canonicalBytes = ClaudeCanonicalEncoder.bytes(
			domain: "claude.disallowedTools.v1",
			fields: ["tools": .strings(Array(toolNames))]
		)
		self.digest = ClaudeSHA256(ClaudeCanonicalDigest.sha256Hex(canonicalBytes))!
	}

	public let canonicalBytes: Data
}

public enum ClaudeWorkingDirectoryClass: String, Hashable, Sendable, CaseIterable {
	case workspaceRoot, disposableOutsideRepo, other
}

// MARK: - Canonical encoding

public enum ClaudeCanonicalDigest {
	public static func sha256Hex(_ data: Data) -> String {
		SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
	}
}

/// The only shapes canonical bytes may contain. There is deliberately no number
/// or floating-point case: a float's textual form is not stable enough to key a
/// durable cache on, and the type system is a better guarantee of that than a
/// review rule.
enum ClaudeCanonicalValue {
	case string(String)
	case bool(Bool)
	/// Emitted sorted, so a set's iteration order cannot reach the digest.
	case strings([String])
}

/// Deterministic JSON-shaped encoder.
///
/// Hand-rolled rather than `JSONEncoder`: that type makes no cross-version
/// guarantee about key order, escaping, or separators, so its output is not a
/// safe basis for a digest that must stay stable across OS and Swift releases.
enum ClaudeCanonicalEncoder {
	static let encodingVersion = "1"

	static func bytes(domain: String, fields: [String: ClaudeCanonicalValue]) -> Data {
		var all = fields
		// Domain separation lives INSIDE the bytes: two key kinds with identical
		// field content must never produce the same digest.
		all["domain"] = .string(domain)
		all["encodingVersion"] = .string(encodingVersion)
		let body = all.keys
			.sorted { $0.utf8.lexicographicallyPrecedes($1.utf8) }
			.map { "\(quoted($0)):\(render(all[$0]!))" }
			.joined(separator: ",")
		return Data("{\(body)}".utf8)
	}

	private static func render(_ value: ClaudeCanonicalValue) -> String {
		switch value {
		case .string(let string):
			return quoted(string)
		case .bool(let flag):
			return flag ? "true" : "false"
		case .strings(let values):
			let sorted = values.sorted { $0.utf8.lexicographicallyPrecedes($1.utf8) }
			return "[" + sorted.map(quoted).joined(separator: ",") + "]"
		}
	}

	/// Byte-order sorting, not `String.<`: collation is a Unicode concern and can
	/// change; byte order cannot.
	private static func quoted(_ string: String) -> String {
		var out = "\""
		for scalar in string.unicodeScalars {
			switch scalar {
			case "\"": out += "\\\""
			case "\\": out += "\\\\"
			case "\n": out += "\\n"
			case "\r": out += "\\r"
			case "\t": out += "\\t"
			default:
				if scalar.value < 0x20 {
					out += String(format: "\\u%04x", scalar.value)
				} else {
					out.unicodeScalars.append(scalar)
				}
			}
		}
		return out + "\""
	}
}

// MARK: - Inputs

public struct ClaudeBehaviorKeyInput: Hashable, Sendable {
	public let cliVersion: ClaudeCliVersion
	public let helpFlagSet: Set<String>
	public let observedCapabilities: Set<String>

	public init(cliVersion: ClaudeCliVersion, helpFlagSet: Set<String>,
				observedCapabilities: Set<String>) {
		self.cliVersion = cliVersion
		self.helpFlagSet = helpFlagSet
		self.observedCapabilities = observedCapabilities
	}

	/// Deliberately excludes binary identity: a behaviour family groups runtimes
	/// that ACT alike, so several tested SHA-256s can belong to one family and the
	/// manifest can accumulate coverage. Identity enters only at certification.
	public var canonicalBytes: Data {
		ClaudeCanonicalEncoder.bytes(domain: "claude.behavior.v1", fields: [
			"cliVersion": .string(cliVersion.description),
			"helpFlagSet": .strings(Array(helpFlagSet)),
			"observedCapabilities": .strings(Array(observedCapabilities))
		])
	}
}

public struct ClaudeLaunchProfileKeyInput: Hashable, Sendable {
	public let commandNameClass: ClaudeCommandNameClass
	public let resumeRequested: Bool
	public let modelRoute: ClaudeModelRoute
	public let effortClass: ClaudeEffortClass
	public let permissionModeClass: ClaudePermissionModeClass
	public let backendClass: ClaudeBackendClass
	public let authenticationModeClass: ClaudeAuthenticationModeClass
	public let workingDirectoryClass: ClaudeWorkingDirectoryClass
	public let mcpConfigPresent: Bool
	public let mcpStrictMode: Bool
	public let disallowedToolsDigest: ClaudeDisallowedToolsDigest

	public init(
		commandNameClass: ClaudeCommandNameClass,
		resumeRequested: Bool,
		modelRoute: ClaudeModelRoute,
		effortClass: ClaudeEffortClass,
		permissionModeClass: ClaudePermissionModeClass,
		backendClass: ClaudeBackendClass,
		authenticationModeClass: ClaudeAuthenticationModeClass,
		workingDirectoryClass: ClaudeWorkingDirectoryClass,
		mcpConfigPresent: Bool,
		mcpStrictMode: Bool,
		disallowedToolsDigest: ClaudeDisallowedToolsDigest
	) {
		self.commandNameClass = commandNameClass
		self.resumeRequested = resumeRequested
		self.modelRoute = modelRoute
		self.effortClass = effortClass
		self.permissionModeClass = permissionModeClass
		self.backendClass = backendClass
		self.authenticationModeClass = authenticationModeClass
		self.workingDirectoryClass = workingDirectoryClass
		self.mcpConfigPresent = mcpConfigPresent
		self.mcpStrictMode = mcpStrictMode
		self.disallowedToolsDigest = disallowedToolsDigest
	}

	/// Seven bounded enums, three Bools, and one domain-separated digest. No raw
	/// path, session ID, credential, or other high-cardinality value can be
	/// expressed here, because the initializer accepts no type that could carry one.
	public var canonicalBytes: Data {
		ClaudeCanonicalEncoder.bytes(domain: "claude.launchProfile.v1", fields: [
			"commandNameClass": .string(commandNameClass.rawValue),
			"resumeRequested": .bool(resumeRequested),
			"modelRoute": .string(modelRoute.rawValue),
			"effortClass": .string(effortClass.rawValue),
			"permissionModeClass": .string(permissionModeClass.rawValue),
			"backendClass": .string(backendClass.rawValue),
			"authenticationModeClass": .string(authenticationModeClass.rawValue),
			"workingDirectoryClass": .string(workingDirectoryClass.rawValue),
			"mcpConfigPresent": .bool(mcpConfigPresent),
			"mcpStrictMode": .bool(mcpStrictMode),
			"disallowedToolsDigest": .string(disallowedToolsDigest.digest.value)
		])
	}
}

public struct ClaudeCertificationKeyInput: Hashable, Sendable {
	public let binarySHA256: ClaudeSHA256
	public let behaviorKey: ClaudeBehaviorKey
	public let launchProfileKey: ClaudeLaunchProfileKey

	public init(binarySHA256: ClaudeSHA256, behaviorKey: ClaudeBehaviorKey,
				launchProfileKey: ClaudeLaunchProfileKey) {
		self.binarySHA256 = binarySHA256
		self.behaviorKey = behaviorKey
		self.launchProfileKey = launchProfileKey
	}

	/// Exactly three inputs: binary identity, behaviour key, launch-profile key.
	public var canonicalBytes: Data {
		ClaudeCanonicalEncoder.bytes(domain: "claude.certification.v1", fields: [
			"binarySHA256": .string(binarySHA256.value),
			"behaviorKey": .string(behaviorKey.digest.value),
			"launchProfileKey": .string(launchProfileKey.digest.value)
		])
	}
}

// MARK: - Keys

public struct ClaudeBehaviorKey: Hashable, Sendable {
	public let digest: ClaudeSHA256
	public init(input: ClaudeBehaviorKeyInput) {
		self.digest = ClaudeSHA256(ClaudeCanonicalDigest.sha256Hex(input.canonicalBytes))!
	}

	/// Narrow wrapper around an already-validated digest — for a manifest record's
	/// bare behaviour hash, which was computed offline and has no local input. Keeps
	/// the behaviour key a DISTINCT type from a launch-profile key, so the two axes
	/// cannot be swapped at a call site.
	public init(digest: ClaudeSHA256) { self.digest = digest }
}

public struct ClaudeLaunchProfileKey: Hashable, Sendable {
	public let digest: ClaudeSHA256
	public init(input: ClaudeLaunchProfileKeyInput) {
		self.digest = ClaudeSHA256(ClaudeCanonicalDigest.sha256Hex(input.canonicalBytes))!
	}

	/// Narrow wrapper around an already-validated digest — for a manifest record's
	/// bare launch-profile hash. Distinct type from a behaviour key (see above).
	public init(digest: ClaudeSHA256) { self.digest = digest }
}

public struct ClaudeCertificationKey: Hashable, Sendable {
	public let digest: ClaudeSHA256
	public init(input: ClaudeCertificationKeyInput) {
		self.digest = ClaudeSHA256(ClaudeCanonicalDigest.sha256Hex(input.canonicalBytes))!
	}

	/// Narrow wrapper around an already-validated digest — for a manifest known-bad
	/// rule's bare certification hash.
	public init(digest: ClaudeSHA256) { self.digest = digest }
}
