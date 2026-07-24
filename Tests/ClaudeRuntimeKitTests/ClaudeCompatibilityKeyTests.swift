import XCTest
@testable import ClaudeRuntimeKit

/// Item 1 of the compatibility-admission plan: the three compatibility keys.
///
/// Golden digests below are computed EXTERNALLY (`shasum -a 256` over the exact
/// byte strings also pinned here), never by the production hasher. Deriving them
/// from `ClaudeCanonicalDigest` would be circular: an incorrect implementation
/// change would move both sides together and stay green.
final class ClaudeCompatibilityKeyTests: XCTestCase {

	private let hexA = String(repeating: "ab12cd34", count: 8)
	private let hexB = String(repeating: "ff00ee11", count: 8)

	// Externally computed constants.
	private let goldenToolsDigest =
		"7cd7d1db630e8662a89e107069c57ed02db8f5fb7081ad2cad325b941014a6a3"
	private let goldenBehaviorDigest =
		"a2b9201e9e7ca0e8d041fa361b3361f993ea61b5bfccec5b3b5ea186042ff09b"
	private let goldenLaunchDigest =
		"662637d3263aa6eab49786ed98a72dca0aa212ba5ef559f5b40ce2e9c2852d23"
	private let goldenCertificationDigest =
		"ece2d8153800593b1d619d8071da9bdb217ff7649f046d3e290f0d29f2243d48"

	private func tools(_ names: Set<String> = ["Bash", "WebFetch"]) -> ClaudeDisallowedToolsDigest {
		ClaudeDisallowedToolsDigest(toolNames: names)
	}

	private func behaviorInput(
		version: String = "2.1.216",
		helpFlags: Set<String> = ["--print", "--verbose"],
		capabilities: Set<String> = ["interrupt_receipt_v1", "msg_lifecycle_v1"]
	) -> ClaudeBehaviorKeyInput {
		ClaudeBehaviorKeyInput(
			cliVersion: ClaudeCliVersion.parse(version)!,
			helpFlagSet: helpFlags,
			observedCapabilities: capabilities
		)
	}

	private func launchInput(
		commandNameClass: ClaudeCommandNameClass = .defaultCommand,
		resumeRequested: Bool = false,
		modelRoute: ClaudeModelRoute = .defaultRoute,
		effortClass: ClaudeEffortClass = .defaultEffort,
		permissionModeClass: ClaudePermissionModeClass = .requireApproval,
		backendClass: ClaudeBackendClass = .standardClaude,
		authenticationModeClass: ClaudeAuthenticationModeClass = .anthropicAPIKey,
		workingDirectoryClass: ClaudeWorkingDirectoryClass = .workspaceRoot,
		mcpConfigPresent: Bool = true,
		mcpStrictMode: Bool = true,
		disallowedToolsDigest: ClaudeDisallowedToolsDigest? = nil
	) -> ClaudeLaunchProfileKeyInput {
		ClaudeLaunchProfileKeyInput(
			commandNameClass: commandNameClass,
			resumeRequested: resumeRequested,
			modelRoute: modelRoute,
			effortClass: effortClass,
			permissionModeClass: permissionModeClass,
			backendClass: backendClass,
			authenticationModeClass: authenticationModeClass,
			workingDirectoryClass: workingDirectoryClass,
			mcpConfigPresent: mcpConfigPresent,
			mcpStrictMode: mcpStrictMode,
			disallowedToolsDigest: disallowedToolsDigest ?? tools()
		)
	}

	private func text(_ data: Data) -> String { String(decoding: data, as: UTF8.self) }

	// MARK: - Golden canonical bytes (complete, exact)

	func testDisallowedToolsGoldenBytes() {
		XCTAssertEqual(
			text(tools().canonicalBytes),
			#"{"domain":"claude.disallowedTools.v1","encodingVersion":"1","tools":["Bash","WebFetch"]}"#
		)
	}

	func testBehaviorGoldenBytes() {
		XCTAssertEqual(
			text(behaviorInput().canonicalBytes),
			#"{"cliVersion":"2.1.216","domain":"claude.behavior.v1","encodingVersion":"1","#
			+ #""helpFlagSet":["--print","--verbose"],"#
			+ #""observedCapabilities":["interrupt_receipt_v1","msg_lifecycle_v1"]}"#
		)
	}

	func testLaunchProfileGoldenBytes() {
		XCTAssertEqual(
			text(launchInput().canonicalBytes),
			#"{"authenticationModeClass":"anthropicAPIKey","backendClass":"standardClaude","#
			+ #""commandNameClass":"defaultCommand","#
			+ #""disallowedToolsDigest":"\#(goldenToolsDigest)","#
			+ #""domain":"claude.launchProfile.v1","effortClass":"defaultEffort","#
			+ #""encodingVersion":"1","mcpConfigPresent":true,"mcpStrictMode":true,"#
			+ #""modelRoute":"defaultRoute","permissionModeClass":"requireApproval","#
			+ #""resumeRequested":false,"workingDirectoryClass":"workspaceRoot"}"#
		)
	}

	/// Complete bytes, not a prefix plus substrings: reordering, an extra field, or
	/// separator drift must all fail.
	func testCertificationGoldenBytes() {
		let input = ClaudeCertificationKeyInput(
			binarySHA256: ClaudeSHA256(hexA)!,
			behaviorKey: ClaudeBehaviorKey(input: behaviorInput()),
			launchProfileKey: ClaudeLaunchProfileKey(input: launchInput())
		)
		XCTAssertEqual(
			text(input.canonicalBytes),
			#"{"behaviorKey":"\#(goldenBehaviorDigest)","binarySHA256":"\#(hexA)","#
			+ #""domain":"claude.certification.v1","encodingVersion":"1","#
			+ #""launchProfileKey":"\#(goldenLaunchDigest)"}"#
		)
	}

	// MARK: - Golden digests (externally computed literals)

	func testGoldenDigestsMatchExternallyComputedValues() {
		XCTAssertEqual(tools().digest.value, goldenToolsDigest)
		XCTAssertEqual(ClaudeBehaviorKey(input: behaviorInput()).digest.value, goldenBehaviorDigest)
		XCTAssertEqual(ClaudeLaunchProfileKey(input: launchInput()).digest.value, goldenLaunchDigest)
		XCTAssertEqual(
			ClaudeCertificationKey(input: ClaudeCertificationKeyInput(
				binarySHA256: ClaudeSHA256(hexA)!,
				behaviorKey: ClaudeBehaviorKey(input: behaviorInput()),
				launchProfileKey: ClaudeLaunchProfileKey(input: launchInput())
			)).digest.value,
			goldenCertificationDigest)
	}

	// MARK: - Set-order invariance

	func testHelpFlagSetOrderDoesNotChangeDigest() {
		XCTAssertEqual(ClaudeBehaviorKey(input: behaviorInput(helpFlags: ["--verbose", "--print"])),
					   ClaudeBehaviorKey(input: behaviorInput(helpFlags: ["--print", "--verbose"])))
	}

	func testDisallowedToolsOrderDoesNotChangeDigest() {
		XCTAssertEqual(tools(["WebFetch", "Bash"]), tools(["Bash", "WebFetch"]))
	}

	// MARK: - Backend contracts

	/// GLM/Z.ai and a custom compatible backend are different runtime contracts.
	/// Collapsing them would let evidence from one certify the other.
	func testEveryBackendContractProducesADistinctKey() {
		var seen = Set<String>()
		for backend in ClaudeBackendClass.allCases {
			let key = ClaudeLaunchProfileKey(input: launchInput(backendClass: backend))
			XCTAssertTrue(seen.insert(key.digest.value).inserted,
						  "backend \(backend.rawValue) collided with another")
		}
		XCTAssertEqual(seen.count, ClaudeBackendClass.allCases.count)
	}

	// MARK: - Authentication contracts

	func testEveryAuthenticationContractProducesADistinctKey() {
		var seen = Set<String>()
		for mode in ClaudeAuthenticationModeClass.allCases {
			let key = ClaudeLaunchProfileKey(input: launchInput(authenticationModeClass: mode))
			XCTAssertTrue(seen.insert(key.digest.value).inserted,
						  "auth mode \(mode.rawValue) collided with another")
		}
		XCTAssertEqual(seen.count, ClaudeAuthenticationModeClass.allCases.count)
	}

	func testBoundedContractVocabulariesArePinned() {
		XCTAssertEqual(Set(ClaudeBackendClass.allCases.map(\.rawValue)),
					   ["standardClaude", "glmZAI", "customCompatible"])
		XCTAssertEqual(Set(ClaudeAuthenticationModeClass.allCases.map(\.rawValue)),
					   ["anthropicAPIKey", "bedrock", "vertexAI", "foundry",
						"enterpriseGateway", "compatibleBackendCredential",
						"userManagedSubscription"])
	}

	// MARK: - Domain separation

	/// Identical field content under different domains must differ in BOTH bytes
	/// and digest.
	func testIdenticalFieldsUnderDifferentDomainsDiffer() {
		let fields: [String: ClaudeCanonicalValue] = ["shared": .string("value")]
		let a = ClaudeCanonicalEncoder.bytes(domain: "claude.behavior.v1", fields: fields)
		let b = ClaudeCanonicalEncoder.bytes(domain: "claude.launchProfile.v1", fields: fields)
		XCTAssertNotEqual(a, b)
		XCTAssertNotEqual(ClaudeCanonicalDigest.sha256Hex(a), ClaudeCanonicalDigest.sha256Hex(b))
	}

	// MARK: - Explicit defaults

	func testExplicitDefaultsAppearInBytes() {
		let encoded = text(launchInput().canonicalBytes)
		XCTAssertTrue(encoded.contains(#""resumeRequested":false"#), encoded)
		XCTAssertTrue(encoded.contains(#""effortClass":"defaultEffort""#), encoded)
	}

	func testEmptyToolSetStillEncodesItsField() {
		XCTAssertTrue(text(tools([]).canonicalBytes).contains(#""tools":[]"#))
	}

	// MARK: - One field at a time

	func testEveryLaunchProfileFieldAffectsTheDigest() {
		let baseline = ClaudeLaunchProfileKey(input: launchInput())
		let variants: [(String, ClaudeLaunchProfileKeyInput)] = [
			("commandNameClass", launchInput(commandNameClass: .explicitPath)),
			("resumeRequested", launchInput(resumeRequested: true)),
			("modelRoute", launchInput(modelRoute: .pinnedModel)),
			("effortClass", launchInput(effortClass: .elevated)),
			("permissionModeClass", launchInput(permissionModeClass: .bypassPermissions)),
			("backendClass", launchInput(backendClass: .glmZAI)),
			("authenticationModeClass", launchInput(authenticationModeClass: .bedrock)),
			("workingDirectoryClass", launchInput(workingDirectoryClass: .disposableOutsideRepo)),
			("mcpConfigPresent", launchInput(mcpConfigPresent: false)),
			("mcpStrictMode", launchInput(mcpStrictMode: false)),
			("disallowedToolsDigest", launchInput(disallowedToolsDigest: tools(["Bash"])))
		]
		for (field, variant) in variants {
			XCTAssertNotEqual(baseline, ClaudeLaunchProfileKey(input: variant),
							  "changing \(field) must change the digest")
		}
	}

	func testEveryBehaviorFieldAffectsTheDigest() {
		let baseline = ClaudeBehaviorKey(input: behaviorInput())
		XCTAssertNotEqual(baseline, ClaudeBehaviorKey(input: behaviorInput(version: "2.1.215")))
		XCTAssertNotEqual(baseline, ClaudeBehaviorKey(input: behaviorInput(helpFlags: ["--print"])))
		XCTAssertNotEqual(baseline, ClaudeBehaviorKey(input: behaviorInput(capabilities: [])))
	}

	func testEveryCertificationFieldAffectsTheDigest() {
		let behavior = ClaudeBehaviorKey(input: behaviorInput())
		let otherBehavior = ClaudeBehaviorKey(input: behaviorInput(version: "2.1.215"))
		let launch = ClaudeLaunchProfileKey(input: launchInput())
		let otherLaunch = ClaudeLaunchProfileKey(input: launchInput(resumeRequested: true))
		let baseline = ClaudeCertificationKey(input: ClaudeCertificationKeyInput(
			binarySHA256: ClaudeSHA256(hexA)!, behaviorKey: behavior, launchProfileKey: launch))

		XCTAssertNotEqual(baseline, ClaudeCertificationKey(input: ClaudeCertificationKeyInput(
			binarySHA256: ClaudeSHA256(hexB)!, behaviorKey: behavior, launchProfileKey: launch)))
		XCTAssertNotEqual(baseline, ClaudeCertificationKey(input: ClaudeCertificationKeyInput(
			binarySHA256: ClaudeSHA256(hexA)!, behaviorKey: otherBehavior, launchProfileKey: launch)))
		XCTAssertNotEqual(baseline, ClaudeCertificationKey(input: ClaudeCertificationKeyInput(
			binarySHA256: ClaudeSHA256(hexA)!, behaviorKey: behavior, launchProfileKey: otherLaunch)))
	}

	// MARK: - Escaping

	func testExactEscapingOfControlAndSpecialCharacters() {
		let cases: [(String, String)] = [
			("a\"b", #""a\"b""#),
			("a\\b", #""a\\b""#),
			("a\nb", #""a\nb""#),
			("a\rb", #""a\rb""#),
			("a\tb", #""a\tb""#),
			("a\u{0008}b", #""a\u0008b""#),   // backspace: generic control-byte path
			("a\u{001F}b", #""a\u001fb""#)    // unit separator: highest escaped control byte
		]
		for (input, expected) in cases {
			let encoded = text(ClaudeCanonicalEncoder.bytes(
				domain: "d", fields: ["k": .string(input)]))
			XCTAssertTrue(encoded.contains(#""k":"# + expected),
						  "\(input.debugDescription) → \(encoded)")
		}
	}
}
