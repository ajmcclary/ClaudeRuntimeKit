import XCTest
import ClaudeRuntimeKit

/// Public-API boundary contract for ClaudeRuntimeKit (the seventh migrate.md
/// extraction and the third provider-runtime promotion). The deep behavior
/// pins live in the 22 per-family suites that moved with the code and reach
/// internals through `@testable`; this file pins what those suites cannot.
/// It deliberately imports **without** `@testable`, so it fails to COMPILE if
/// any type RepoPrompt consumes is de-publicized by a later edit.
///
/// Three obligations:
///   1. every vocabulary family the app reaches through the ClaudeRuntimeCore
///      shim stays public (the typealias pins below);
///   2. the raw values that are PERSISTED or that cross a wire/manifest
///      boundary keep their exact spellings — these are compatibility
///      identity, not implementation detail;
///   3. the evidence-tier and admission vocabularies stay CLOSED, so a later
///      edit cannot quietly widen a certification claim.
final class ClaudeRuntimeKitPublicAPIContractTests: XCTestCase {

	// MARK: - Compile-time public-visibility pins
	//
	// A tuple type references each member without needing a constructible
	// value; removing or de-publicizing any member is a compile error here.

	private typealias CompatibilityKeyFamily = (
		ClaudeCommandNameClass, ClaudeModelRoute, ClaudeEffortClass,
		ClaudePermissionModeClass, ClaudeBackendClass, ClaudeAuthenticationModeClass,
		ClaudeWorkingDirectoryClass, ClaudeDisallowedToolsDigest, ClaudeCanonicalDigest,
		ClaudeBehaviorKeyInput, ClaudeLaunchProfileKeyInput, ClaudeCertificationKeyInput,
		ClaudeBehaviorKey, ClaudeLaunchProfileKey, ClaudeCertificationKey)

	private typealias ManifestFamily = (
		ClaudeFamilyClassification, ClaudeCapabilityState, ClaudeInterruptMethod,
		ClaudeAbortSignal, ClaudeCapabilityEvidence, ClaudeInterruptCapability,
		ClaudeFamilyCapabilities, ClaudeCliVersionRange, ClaudeCertifiedIdentity,
		ClaudeManifestFamily, ClaudeKnownBadMatch, ClaudeKnownBadRule,
		ClaudeCompatibilityManifest, ClaudeManifestDecodingError)

	private typealias IdentityFamily = (
		ClaudeCliVersion, ClaudeSHA256, ClaudeExecutableSigningClass,
		ClaudeExecutablePathClass, ClaudeRuntimeUnresolvableReason,
		ClaudeRuntimeIdentity, ClaudeRuntimeResolution)

	private typealias AdmissionFamily = (
		ClaudePrelaunchQuery, ClaudePostInitializeQuery, ClaudeOfferedCapabilities,
		ClaudeMatchedClassification, ClaudeAdmissionAssessment, ClaudeLimitedAdmissionReason,
		ClaudeAdmissionRejectReason, ClaudeAdmissionDecision, ClaudeAdmissionEvaluation,
		ClaudeAdmissionCoordinator, ClaudeAdmissionEnforcementStage, ClaudeEnforcementOverride,
		ClaudeAdmissionEnforcementResolution, ClaudeBehavioralValidationFailure,
		ClaudeBehavioralValidationOutcome, ClaudeBehavioralValidator)

	private typealias WireFamily = (
		ClaudeEventEnvelope, ClaudeJSONValue, ClaudeRuntimeEvent,
		ClaudePartialToolInputAssembler, ClaudeCredentialRedactor,
		ClaudeRuntimeDiagnostic, ClaudeRuntimeDiagnosticAccumulator)

	private typealias LifecycleFamily = (
		ClaudeTransportEpoch, ClaudeTurnGeneration, ClaudeHostLifecycleSignal,
		ClaudeLifecycleInput, ClaudeStampedLifecycleInput, ClaudeLifecycleIngressStamper,
		ClaudeLifecycleRunState, ClaudeLifecycleIdentity, ClaudeLifecycleScope,
		ClaudeLifecycleEvent, ClaudeLifecycleNormalizer, ClaudeTurnOutcome,
		ClaudeCompletionTrigger, ClaudeLifecycleDecision, ClaudeShadowLifecycleRecord,
		ClaudeLifecycleReconciler, ClaudeReconciledCompletion, ClaudeLifecycleParityMismatch,
		ClaudeExpectedLifecycleDivergence, ClaudeLifecycleParity, ClaudeLifecycleDrift,
		ClaudeLifecycleDriftRecorder)

	private typealias UsageFamily = (
		ClaudeUsagePhase, ClaudeUsageScope, ClaudeUsageIdentity,
		ClaudeUsageBreakdown, ClaudeUsageLedger)

	// MARK: - Persisted / manifest-facing raw values

	/// These strings appear in `claude-compatibility-manifest.json` and in the
	/// JSON Schema that validates it (both app-side). Renaming a case here
	/// silently invalidates every packaged manifest, so the spellings are
	/// pinned on this side of the boundary too.
	func testManifestVocabularyRawValuesArePinned() {
		XCTAssertEqual(ClaudeFamilyClassification.supported.rawValue, "supported")
		XCTAssertEqual(ClaudeFamilyClassification.limited.rawValue, "limited")
		XCTAssertEqual(ClaudeFamilyClassification.externalOnly.rawValue, "external-only")
		XCTAssertEqual(ClaudeCapabilityState.certified.rawValue, "certified")
		XCTAssertEqual(ClaudeCapabilityState.uncertified.rawValue, "uncertified")
		XCTAssertEqual(ClaudeInterruptMethod.inFlightCanary.rawValue, "in-flight-canary")
		XCTAssertEqual(ClaudeAbortSignal.assistantAborted.rawValue, "assistant.aborted==true")
		XCTAssertEqual(
			ClaudeAbortSignal.resultTerminalReasonAbortedStreaming.rawValue,
			"result.terminal_reason==aborted_streaming")
	}

	/// The evidence vocabularies stay CLOSED. Widening any of them is how a
	/// certification claim broadens without a decision being recorded — the
	/// single interrupt method and the exactly-two abort signals are the
	/// item-2 spike's surviving conclusions.
	func testEvidenceVocabulariesStayClosed() {
		XCTAssertEqual(ClaudeFamilyClassification.allCases.count, 3)
		XCTAssertEqual(ClaudeCapabilityState.allCases.count, 2)
		XCTAssertEqual(ClaudeInterruptMethod.allCases, [.inFlightCanary])
		XCTAssertEqual(ClaudeAbortSignal.allCases.count, 2)
		XCTAssertEqual(ClaudeExecutableSigningClass.allCases.count, 7)
	}

	/// The launch-profile axis vocabularies are what a `certificationKey` is
	/// keyed under. A new case multiplies the certified-identity surface, so
	/// the counts are pinned deliberately rather than derived.
	func testLaunchProfileAxisVocabulariesArePinned() {
		XCTAssertEqual(ClaudeCommandNameClass.allCases.count, 3)
		XCTAssertEqual(ClaudeModelRoute.allCases.count, 3)
		XCTAssertEqual(ClaudeEffortClass.allCases.count, 3)
		XCTAssertEqual(ClaudePermissionModeClass.allCases.count, 4)
		XCTAssertEqual(ClaudeBackendClass.allCases.count, 3)
		XCTAssertEqual(ClaudeAuthenticationModeClass.allCases.count, 7)
		XCTAssertEqual(ClaudeWorkingDirectoryClass.allCases.count, 3)
		XCTAssertEqual(ClaudeUsagePhase.turnAggregate.rawValue, "turnAggregate")
		XCTAssertEqual(ClaudeUsagePhase.assistantSnapshot.rawValue, "assistantSnapshot")
	}

	// MARK: - Behavior reachable through the public surface only

	/// Domain separation lives INSIDE the canonical bytes, so the same field
	/// set under two domains must not collide. Asserted here through the
	/// PUBLIC key types (the encoder itself is deliberately internal), which
	/// is the property an external consumer can actually depend on.
	func testCanonicalDigestsSeparateDomainsThroughPublicKeyTypes() {
		let version = try! XCTUnwrap(ClaudeCliVersion.parse("2.1.216"))
		let behavior = ClaudeBehaviorKey(input: ClaudeBehaviorKeyInput(
			cliVersion: version, helpFlagSet: ["--print"], observedCapabilities: ["resume"]))
		let sha = try! XCTUnwrap(ClaudeSHA256(String(repeating: "a", count: 64)))
		let profile = ClaudeLaunchProfileKey(input: ClaudeLaunchProfileKeyInput(
			commandNameClass: .defaultCommand, resumeRequested: false,
			modelRoute: .defaultRoute, effortClass: .defaultEffort,
			permissionModeClass: .requireApproval, backendClass: .standardClaude,
			authenticationModeClass: .anthropicAPIKey, workingDirectoryClass: .workspaceRoot,
			mcpConfigPresent: true, mcpStrictMode: false,
			disallowedToolsDigest: ClaudeDisallowedToolsDigest(toolNames: [])))
		let certification = ClaudeCertificationKey(input: ClaudeCertificationKeyInput(
			binarySHA256: sha, behaviorKey: behavior, launchProfileKey: profile))

		XCTAssertEqual(behavior.digest.value.count, 64)
		XCTAssertNotEqual(behavior.digest.value, profile.digest.value)
		XCTAssertNotEqual(certification.digest.value, behavior.digest.value)
		XCTAssertNotEqual(certification.digest.value, profile.digest.value)
	}

	/// `ClaudeSHA256` REJECTS uppercase rather than normalizing it: a digest
	/// arriving in the wrong case means a malformed producer. That is a
	/// public-surface guarantee the app's identity resolver relies on.
	func testSHA256ValidationIsRejectingNotNormalizing() {
		XCTAssertNotNil(ClaudeSHA256(String(repeating: "a", count: 64)))
		XCTAssertNil(ClaudeSHA256(String(repeating: "A", count: 64)))
		XCTAssertNil(ClaudeSHA256(String(repeating: "a", count: 63)))
		XCTAssertNil(ClaudeSHA256(""))
	}

	/// The decoder is an INDEPENDENT fail-closed gate, not a subset of the
	/// JSON Schema, and it never manufactures `.empty` — only the application
	/// does, for an ABSENT manifest. Both halves are boundary contract.
	func testManifestDecoderIsFailClosedAndNeverProducesEmpty() {
		XCTAssertThrowsError(try ClaudeCompatibilityManifest.decode(from: Data("not json".utf8)))
		// families: [] is `minItems: 1` — a packaged empty manifest FAILS.
		let emptyFamilies = """
			{"schemaVersion":1,"manifestVersion":"2026-07-21.1","families":[],"knownBadRules":[]}
			"""
		XCTAssertThrowsError(
			try ClaudeCompatibilityManifest.decode(from: Data(emptyFamilies.utf8))
		) { error in
			XCTAssertEqual(
				error as? ClaudeManifestDecodingError, .emptyArray(field: "families"))
		}
		// The conservative stand-in is application-constructed and stays reachable.
		XCTAssertTrue(ClaudeCompatibilityManifest.empty.families.isEmpty)
		XCTAssertEqual(ClaudeCompatibilityManifest.empty.schemaVersion, 1)
		XCTAssertEqual(ClaudeCompatibilityManifest.empty.manifestVersion, "")
	}

	/// Version parsing and ordering back the manifest's `cliVersionRange`.
	func testCliVersionParsingAndOrderingStayPublic() {
		XCTAssertEqual(ClaudeCliVersion.parse("2.1.216 (Claude Code)"),
					   ClaudeCliVersion.parse("2.1.216"))
		XCTAssertNil(ClaudeCliVersion.parse("2.1"))
		let older = try! XCTUnwrap(ClaudeCliVersion.parse("2.1.215"))
		let newer = try! XCTUnwrap(ClaudeCliVersion.parse("2.1.216"))
		XCTAssertLessThan(older, newer)
		XCTAssertEqual(newer.description, "2.1.216")
	}

	/// The envelope decodes bytes losslessly and never drops evidence — a
	/// non-object line stays non-decodable but keeps its raw bytes.
	func testEventEnvelopeDecodeIsLosslessThroughPublicAPI() {
		let object = ClaudeEventEnvelope.decode(line: Data(#"{"type":"result","session_id":"s"}"#.utf8))
		XCTAssertTrue(object.isDecodable)
		XCTAssertEqual(object.type, "result")
		XCTAssertEqual(object.sessionID, "s")

		let garbage = ClaudeEventEnvelope.decode(line: Data("not-json".utf8))
		XCTAssertFalse(garbage.isDecodable)
		XCTAssertEqual(garbage.rawBytes, Data("not-json".utf8))
	}

	/// Structural, key-based redaction — the property the app's diagnostic
	/// lane and its `ClaudeCredentialRedactor+Authentication` extension both
	/// build on. Structure survives; sensitive values do not.
	func testCredentialRedactionIsStructuralAndKeyBased() {
		XCTAssertEqual(ClaudeCredentialRedactor.placeholder, "<redacted>")
		XCTAssertTrue(ClaudeCredentialRedactor.isSensitiveKey("ANTHROPIC_API_KEY"))
		XCTAssertTrue(ClaudeCredentialRedactor.isSensitiveKey("token"))
		XCTAssertFalse(ClaudeCredentialRedactor.isSensitiveKey("tokens"))
		let redacted = ClaudeCredentialRedactor.redact(
			["outer": ["authorization": "Bearer live", "model": "opus"]]) as? [String: Any]
		let inner = redacted?["outer"] as? [String: Any]
		XCTAssertEqual(inner?["authorization"] as? String, "<redacted>")
		XCTAssertEqual(inner?["model"] as? String, "opus")
	}

	/// The normalized lane exposes `ClaudeJSONValue`, never `[String: Any]`
	/// (the Slice-2 ratchet that `verify-claude-runtime-boundary.py` R10 also
	/// gates from the outside).
	func testJSONValueBridgesWithoutLeakingUntypedDictionaries() {
		XCTAssertEqual(ClaudeJSONValue.from(1 as NSNumber), .number(1))
		XCTAssertEqual(ClaudeJSONValue.from(true as NSNumber), .bool(true))
		XCTAssertEqual(ClaudeJSONValue.from(nil), .null)
		XCTAssertEqual(
			ClaudeJSONValue.from(["a": [1 as NSNumber, "b"]] as [String: Any]),
			.object(["a": .array([.number(1), .string("b")])]))
	}

	/// Replay-safe usage identity: an explicit `messageID` discards the
	/// producer's ordinal, which is what makes replay and resume idempotent.
	func testUsageIdentityDiscardsOrdinalWhenMessageIDIsPresent() {
		let withMessage = ClaudeUsageIdentity(
			sessionID: "s", messageID: "m", phase: .assistantSnapshot, ordinal: 9)
		XCTAssertNil(withMessage.ordinal)
		let withoutMessage = ClaudeUsageIdentity(
			sessionID: "s", messageID: nil, phase: .assistantSnapshot, ordinal: 9)
		XCTAssertEqual(withoutMessage.ordinal, 9)
		XCTAssertNotEqual(withMessage, withoutMessage)
	}
}
