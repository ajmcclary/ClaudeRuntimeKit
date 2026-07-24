import Foundation

// Item 1 of the compatibility-admission plan. Pure values and bounded
// classifications only.
//
// This module has no dependencies, so it cannot reference `CommandPathResolver`
// or any other app type — the boundary is enforced by the package graph rather
// than by review. The single app-side resolver owns every filesystem and process
// read (realpath, hashing, stat, codesign) and maps its `CLIExecutableLaunchability`
// outcomes into the bounded cases below.

/// A validated SHA-256 digest: exactly 64 lowercase ASCII hex characters.
///
/// Uppercase is **rejected, not normalised**. Lowercasing would canonicalise just
/// as well, so this is not about avoiding duplicate cache entries — it is a
/// producer-invariant check: a digest arriving in the wrong case means the
/// producer is malformed, and surfacing that is more useful than repairing it.
public struct ClaudeSHA256: Hashable, Sendable, CustomStringConvertible {
	public let value: String

	public init?(_ raw: String) {
		guard raw.count == 64,
			  raw.allSatisfy({ $0.isASCII && ($0.isNumber || ("a"..."f").contains($0)) })
		else { return nil }
		self.value = raw
	}

	public var description: String { value }
}

/// How an executable's code signature classifies.
///
/// Distinguishing these matters because they are different trust classes that a
/// coarser vocabulary silently conflates: an Apple **Development** certificate is
/// Apple-anchored and carries a team identifier in its subject OU exactly like a
/// Developer ID certificate, so a requirement matching only those two properties
/// would label a development build as a distributed one.
public enum ClaudeExecutableSigningClass: String, Hashable, Sendable, CaseIterable {
	/// Validated against the Developer ID Application certificate marker.
	case appleDeveloperID
	/// Apple platform binary (a system executable). No team identifier.
	case applePlatform
	/// A valid signature that is neither Developer ID nor platform — e.g. Apple
	/// Development, or an enterprise certificate.
	case otherSigned
	case adHoc
	case unsigned
	/// Signature metadata was readable, but the signature failed validation.
	/// Distinct from `unreadable`: the bytes claim a signature that does not hold.
	case invalid
	/// The signature could not be inspected at all.
	case unreadable
}

public enum ClaudeExecutablePathClass: String, Hashable, Sendable, CaseIterable {
	case homebrew
	case npmGlobal
	case userLocal
	case system
	case unknown
}

/// Why an executable could not be identified. Bounded semantic cases only — never
/// a raw `Error`, a path, or a system message, both because those are unbounded
/// and because they would carry user-identifying detail into telemetry.
public enum ClaudeRuntimeUnresolvableReason: String, Hashable, Sendable, CaseIterable {
	/// Resolution produced a bare command name with no path — nothing to hash.
	case noPath
	case missingPath
	case notExecutable
	case isDirectory
	/// The bytes could not be read to completion.
	case hashUnreadable
	/// Symlinks could not be resolved to a canonical path. Distinct from
	/// `hashUnreadable`: falling back to the non-canonical path would make
	/// `realPath` inaccurate and would classify `pathClass` before symlink
	/// resolution, which the classification depends on.
	case canonicalPathUnreadable
}

public struct ClaudeRuntimeIdentity: Hashable, Sendable {
	public let resolvedPath: String
	public let realPath: String
	public let sha256: ClaudeSHA256
	public let sizeBytes: Int
	public let signingClass: ClaudeExecutableSigningClass
	public let pathClass: ClaudeExecutablePathClass

	public init?(
		resolvedPath: String,
		realPath: String,
		sha256: ClaudeSHA256,
		sizeBytes: Int,
		signingClass: ClaudeExecutableSigningClass,
		pathClass: ClaudeExecutablePathClass
	) {
		guard !resolvedPath.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
			  !realPath.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
			  sizeBytes >= 0
		else { return nil }
		self.resolvedPath = resolvedPath
		self.realPath = realPath
		self.sha256 = sha256
		self.sizeBytes = sizeBytes
		self.signingClass = signingClass
		self.pathClass = pathClass
	}
}

public enum ClaudeRuntimeResolution: Hashable, Sendable {
	case resolved(ClaudeRuntimeIdentity)
	case unresolvable(ClaudeRuntimeUnresolvableReason)
}
