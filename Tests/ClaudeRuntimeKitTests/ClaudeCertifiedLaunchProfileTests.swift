import XCTest
@testable import ClaudeRuntimeKit

/// Item 3, first test: prove the certified launch profile's key through the REAL
/// `ClaudeLaunchProfileKeyInput`.
///
/// The interrupt canary (2026-07-21) certified two binary identities under one
/// canonical launch profile, and the spike report recorded that profile's key as
/// `e831b109…`. That value was derived EXTERNALLY, from the canonical-byte
/// contract — never by the production hasher. Until this suite passes, the
/// recorded constant and the shipping implementation are only assumed to agree.
///
/// Goldens here follow `ClaudeCompatibilityKeyTests`'s convention: computed with
/// `shasum -a 256` over the exact byte strings also pinned below, never by calling
/// `ClaudeCanonicalDigest`. Deriving a golden from the production hasher would be
/// circular — an incorrect encoder change would move both sides together and stay
/// green.
final class ClaudeCertifiedLaunchProfileTests: XCTestCase {

	// MARK: - Externally computed constants

	/// `shasum -a 256` over `expectedToolsCanonicalBytes`.
	private let goldenEmptyToolsDigest =
		"f3d8cb907f84cb9f51ac419bc26ae134a48805f36b09c7f8139b60be843fd9ab"

	/// `shasum -a 256` over `expectedProfileCanonicalBytes`.
	private let goldenCertifiedLaunchProfileKey =
		"e831b109495ed27b600b61725fcc7fea03ce4d3dafe4654b9653035897feb0dc"

	private let expectedToolsCanonicalBytes =
		#"{"domain":"claude.disallowedTools.v1","encodingVersion":"1","tools":[]}"#

	private let expectedProfileCanonicalBytes = """
		{"authenticationModeClass":"anthropicAPIKey",\
		"backendClass":"standardClaude",\
		"commandNameClass":"explicitPath",\
		"disallowedToolsDigest":"f3d8cb907f84cb9f51ac419bc26ae134a48805f36b09c7f8139b60be843fd9ab",\
		"domain":"claude.launchProfile.v1",\
		"effortClass":"defaultEffort",\
		"encodingVersion":"1",\
		"mcpConfigPresent":true,\
		"mcpStrictMode":true,\
		"modelRoute":"defaultRoute",\
		"permissionModeClass":"requireApproval",\
		"resumeRequested":false,\
		"workingDirectoryClass":"disposableOutsideRepo"}
		"""

	/// The canary SCRIPT's own key. Present only so its absence can be asserted.
	/// It must never be imported as a production key: the script hashed
	/// `"explicitAPIKey"` rather than the `anthropicAPIKey` the production enum
	/// spells, and used a bare `sha256("")` tools digest instead of the
	/// domain-separated wrapper. It is provenance, not identity.
	private let canaryLocalProvenanceKey =
		"0bd0f78203c401cf"

	// MARK: - The certified profile

	/// The exact eleven-field profile the canary certified (spike report §6.3).
	private func certifiedProfileInput() -> ClaudeLaunchProfileKeyInput {
		ClaudeLaunchProfileKeyInput(
			commandNameClass: .explicitPath,
			resumeRequested: false,
			modelRoute: .defaultRoute,
			effortClass: .defaultEffort,
			permissionModeClass: .requireApproval,
			backendClass: .standardClaude,
			authenticationModeClass: .anthropicAPIKey,
			workingDirectoryClass: .disposableOutsideRepo,
			mcpConfigPresent: true,
			mcpStrictMode: true,
			disallowedToolsDigest: ClaudeDisallowedToolsDigest(toolNames: [])
		)
	}

	// MARK: - Tests

	/// Encoding and hashing are asserted separately so a failure localizes: a byte
	/// mismatch is an encoder change, a digest mismatch with matching bytes is a
	/// hashing change.
	func testEmptyDisallowedToolsDigestMatchesExternallyComputedGolden() {
		let digest = ClaudeDisallowedToolsDigest(toolNames: [])
		XCTAssertEqual(
			String(decoding: digest.canonicalBytes, as: UTF8.self),
			expectedToolsCanonicalBytes,
			"canonical encoding of the empty disallowed-tools set changed"
		)
		XCTAssertEqual(
			digest.digest.value, goldenEmptyToolsDigest,
			"empty-set tools digest no longer matches the externally computed golden"
		)
	}

	func testCertifiedLaunchProfileCanonicalBytesMatchTheRecordedContract() {
		XCTAssertEqual(
			String(decoding: certifiedProfileInput().canonicalBytes, as: UTF8.self),
			expectedProfileCanonicalBytes,
			"canonical encoding of the certified launch profile changed"
		)
	}

	/// THE assertion item 3 owed: the recorded constant and the production hasher
	/// agree, rather than the constant being trusted on its own.
	func testCertifiedLaunchProfileKeyMatchesTheRecordedConstant() {
		let key = ClaudeLaunchProfileKey(input: certifiedProfileInput())
		XCTAssertEqual(
			key.digest.value, goldenCertifiedLaunchProfileKey,
			"the certified launch-profile key no longer matches the value recorded in "
			+ "docs/research/claude-interrupt-certification-spike-2026-07-21.md §6.3"
		)
	}

	/// The canary-local key must never be reachable from production inputs. If a
	/// future edit made the production profile reproduce it, the evidence boundary
	/// the spike drew would have collapsed silently.
	func testCertifiedKeyIsNotTheCanaryLocalProvenanceKey() {
		let key = ClaudeLaunchProfileKey(input: certifiedProfileInput()).digest.value
		XCTAssertFalse(
			key.hasPrefix(canaryLocalProvenanceKey),
			"production profile reproduced the canary-local provenance key — the canary "
			+ "hashed a different authentication spelling and a non-domain-separated "
			+ "tools digest, so these must never coincide"
		)
	}

	/// Anti-vacuity: the key must actually depend on the fields it hashes. Without
	/// this, the three assertions above could pass against a constant.
	func testEveryCertifiedProfileFieldChangeMovesTheKey() {
		let baseline = ClaudeLaunchProfileKey(input: certifiedProfileInput()).digest.value

		let variants: [(String, ClaudeLaunchProfileKeyInput)] = [
			("commandNameClass", ClaudeLaunchProfileKeyInput(
				commandNameClass: .defaultCommand, resumeRequested: false,
				modelRoute: .defaultRoute, effortClass: .defaultEffort,
				permissionModeClass: .requireApproval, backendClass: .standardClaude,
				authenticationModeClass: .anthropicAPIKey,
				workingDirectoryClass: .disposableOutsideRepo,
				mcpConfigPresent: true, mcpStrictMode: true,
				disallowedToolsDigest: ClaudeDisallowedToolsDigest(toolNames: []))),
			("resumeRequested", ClaudeLaunchProfileKeyInput(
				commandNameClass: .explicitPath, resumeRequested: true,
				modelRoute: .defaultRoute, effortClass: .defaultEffort,
				permissionModeClass: .requireApproval, backendClass: .standardClaude,
				authenticationModeClass: .anthropicAPIKey,
				workingDirectoryClass: .disposableOutsideRepo,
				mcpConfigPresent: true, mcpStrictMode: true,
				disallowedToolsDigest: ClaudeDisallowedToolsDigest(toolNames: []))),
			("modelRoute", ClaudeLaunchProfileKeyInput(
				commandNameClass: .explicitPath, resumeRequested: false,
				modelRoute: .pinnedModel, effortClass: .defaultEffort,
				permissionModeClass: .requireApproval, backendClass: .standardClaude,
				authenticationModeClass: .anthropicAPIKey,
				workingDirectoryClass: .disposableOutsideRepo,
				mcpConfigPresent: true, mcpStrictMode: true,
				disallowedToolsDigest: ClaudeDisallowedToolsDigest(toolNames: []))),
			("effortClass", ClaudeLaunchProfileKeyInput(
				commandNameClass: .explicitPath, resumeRequested: false,
				modelRoute: .defaultRoute, effortClass: .reduced,
				permissionModeClass: .requireApproval, backendClass: .standardClaude,
				authenticationModeClass: .anthropicAPIKey,
				workingDirectoryClass: .disposableOutsideRepo,
				mcpConfigPresent: true, mcpStrictMode: true,
				disallowedToolsDigest: ClaudeDisallowedToolsDigest(toolNames: []))),
			("permissionModeClass", ClaudeLaunchProfileKeyInput(
				commandNameClass: .explicitPath, resumeRequested: false,
				modelRoute: .defaultRoute, effortClass: .defaultEffort,
				permissionModeClass: .bypassPermissions, backendClass: .standardClaude,
				authenticationModeClass: .anthropicAPIKey,
				workingDirectoryClass: .disposableOutsideRepo,
				mcpConfigPresent: true, mcpStrictMode: true,
				disallowedToolsDigest: ClaudeDisallowedToolsDigest(toolNames: []))),
			("backendClass", ClaudeLaunchProfileKeyInput(
				commandNameClass: .explicitPath, resumeRequested: false,
				modelRoute: .defaultRoute, effortClass: .defaultEffort,
				permissionModeClass: .requireApproval, backendClass: .glmZAI,
				authenticationModeClass: .anthropicAPIKey,
				workingDirectoryClass: .disposableOutsideRepo,
				mcpConfigPresent: true, mcpStrictMode: true,
				disallowedToolsDigest: ClaudeDisallowedToolsDigest(toolNames: []))),
			("authenticationModeClass", ClaudeLaunchProfileKeyInput(
				commandNameClass: .explicitPath, resumeRequested: false,
				modelRoute: .defaultRoute, effortClass: .defaultEffort,
				permissionModeClass: .requireApproval, backendClass: .standardClaude,
				authenticationModeClass: .userManagedSubscription,
				workingDirectoryClass: .disposableOutsideRepo,
				mcpConfigPresent: true, mcpStrictMode: true,
				disallowedToolsDigest: ClaudeDisallowedToolsDigest(toolNames: []))),
			("workingDirectoryClass", ClaudeLaunchProfileKeyInput(
				commandNameClass: .explicitPath, resumeRequested: false,
				modelRoute: .defaultRoute, effortClass: .defaultEffort,
				permissionModeClass: .requireApproval, backendClass: .standardClaude,
				authenticationModeClass: .anthropicAPIKey,
				workingDirectoryClass: .workspaceRoot,
				mcpConfigPresent: true, mcpStrictMode: true,
				disallowedToolsDigest: ClaudeDisallowedToolsDigest(toolNames: []))),
			("mcpConfigPresent", ClaudeLaunchProfileKeyInput(
				commandNameClass: .explicitPath, resumeRequested: false,
				modelRoute: .defaultRoute, effortClass: .defaultEffort,
				permissionModeClass: .requireApproval, backendClass: .standardClaude,
				authenticationModeClass: .anthropicAPIKey,
				workingDirectoryClass: .disposableOutsideRepo,
				mcpConfigPresent: false, mcpStrictMode: true,
				disallowedToolsDigest: ClaudeDisallowedToolsDigest(toolNames: []))),
			("mcpStrictMode", ClaudeLaunchProfileKeyInput(
				commandNameClass: .explicitPath, resumeRequested: false,
				modelRoute: .defaultRoute, effortClass: .defaultEffort,
				permissionModeClass: .requireApproval, backendClass: .standardClaude,
				authenticationModeClass: .anthropicAPIKey,
				workingDirectoryClass: .disposableOutsideRepo,
				mcpConfigPresent: true, mcpStrictMode: false,
				disallowedToolsDigest: ClaudeDisallowedToolsDigest(toolNames: []))),
			("disallowedToolsDigest", ClaudeLaunchProfileKeyInput(
				commandNameClass: .explicitPath, resumeRequested: false,
				modelRoute: .defaultRoute, effortClass: .defaultEffort,
				permissionModeClass: .requireApproval, backendClass: .standardClaude,
				authenticationModeClass: .anthropicAPIKey,
				workingDirectoryClass: .disposableOutsideRepo,
				mcpConfigPresent: true, mcpStrictMode: true,
				disallowedToolsDigest: ClaudeDisallowedToolsDigest(toolNames: ["Bash"])))
		]

		XCTAssertEqual(variants.count, 11, "every hashed field must have a variant")
		for (field, variant) in variants {
			XCTAssertNotEqual(
				ClaudeLaunchProfileKey(input: variant).digest.value, baseline,
				"changing \(field) did not move the launch-profile key"
			)
		}
	}
}
