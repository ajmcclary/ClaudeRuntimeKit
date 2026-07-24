import XCTest
@testable import ClaudeRuntimeKit

// Item 5: the §4.8 decision table across both phases, per-capability projection
// (§9.1.16), known-bad precedence on DERIVED keys, and stage-0 inertness — under
// the corrected model where a runtime behaviour key is UNAVAILABLE pre-turn.
//
// Corrections pinned here:
//   • No behaviour-key input. An identity is bound by an exact SHA + launch-profile
//     match to a manifest record; anything else is `behaviourUnavailable` and fails
//     closed under enforcement (never `limited`, never fabricated).
//   • Enum queries make the resolved/unresolvable pairing structural.
//   • Certification key for a bound identity is DERIVED; an arbitrary value can't fire.
//   • Stage-0 decision is `.admitUnrestricted`; the projection is telemetry-only.
//   • `.notPerformed` never satisfies the final post-initialize decision at stage ≥1.

final class ClaudeAdmissionCoordinatorTests: XCTestCase {

	// MARK: - Realistic typed fixtures

	private let cli = ClaudeCliVersion.parse("2.1.215")!
	private lazy var behaviorKey = ClaudeBehaviorKey(input: ClaudeBehaviorKeyInput(
		cliVersion: cli, helpFlagSet: ["--print", "--verbose"],
		observedCapabilities: ["interrupt_receipt_v1", "msg_lifecycle_v1"]))
	private lazy var launchProfileKey = ClaudeLaunchProfileKey(input: ClaudeLaunchProfileKeyInput(
		commandNameClass: .explicitPath, resumeRequested: false, modelRoute: .defaultRoute,
		effortClass: .defaultEffort, permissionModeClass: .requireApproval,
		backendClass: .standardClaude, authenticationModeClass: .anthropicAPIKey,
		workingDirectoryClass: .disposableOutsideRepo, mcpConfigPresent: true, mcpStrictMode: true,
		disallowedToolsDigest: ClaudeDisallowedToolsDigest(toolNames: [])))
	private let certifiedSha = ClaudeSHA256(String(repeating: "b", count: 64))!

	private func sha(_ c: Character) -> ClaudeSHA256 { ClaudeSHA256(String(repeating: c, count: 64))! }

	private var derivedCertificationKey: ClaudeCertificationKey {
		ClaudeCertificationKey(input: ClaudeCertificationKeyInput(
			binarySHA256: certifiedSha, behaviorKey: behaviorKey, launchProfileKey: launchProfileKey))
	}

	private func identity(_ sha: ClaudeSHA256) -> ClaudeRuntimeIdentity {
		ClaudeRuntimeIdentity(resolvedPath: "/x/claude", realPath: "/x/claude", sha256: sha,
			sizeBytes: 1, signingClass: .appleDeveloperID, pathClass: .userLocal)!
	}

	private func capabilities(interrupt: ClaudeCapabilityState = .certified,
							  resume: ClaudeCapabilityState = .uncertified,
							  structuredOutput: ClaudeCapabilityState = .uncertified)
	-> ClaudeFamilyCapabilities {
		ClaudeFamilyCapabilities(
			models: [], effortLevels: [],
			structuredOutput: ClaudeCapabilityEvidence(state: structuredOutput, evidence: ""),
			resume: ClaudeCapabilityEvidence(state: resume, evidence: ""),
			interrupt: ClaudeInterruptCapability(state: interrupt, method: .inFlightCanary,
				abortSignals: [.assistantAborted, .resultTerminalReasonAbortedStreaming],
				evidence: "canary:x"),
			permissionModeRoundTrip: true)
	}

	private func family(classification: ClaudeFamilyClassification = .supported,
						capabilities caps: ClaudeFamilyCapabilities? = nil) -> ClaudeManifestFamily {
		ClaudeManifestFamily(
			behaviorKey: behaviorKey,
			cliVersionRange: ClaudeCliVersionRange(min: cli, max: cli),
			certifiedIdentities: [ClaudeCertifiedIdentity(
				sha256: certifiedSha, launchProfileKey: launchProfileKey,
				signingClass: .appleDeveloperID)],
			classification: classification, capabilities: caps ?? capabilities(),
			limitations: classification == .supported ? [] : ["family says limited"],
			evidence: ["some evidence"])
	}

	private func manifest(_ families: [ClaudeManifestFamily],
						  knownBad: [ClaudeKnownBadRule] = []) -> ClaudeCompatibilityManifest {
		ClaudeCompatibilityManifest(schemaVersion: 1, manifestVersion: "2026-07-21.1",
									families: families, knownBadRules: knownBad)
	}

	private func postInit(sha: ClaudeSHA256? = nil,
						  validation: ClaudeBehavioralValidationOutcome = .passed)
	-> ClaudePostInitializeQuery {
		.resolved(identity: identity(sha ?? certifiedSha), launchProfileKey: launchProfileKey,
				  validation: validation)
	}

	private func prelaunch(sha: ClaudeSHA256? = nil) -> ClaudePrelaunchQuery {
		.resolved(identity: identity(sha ?? certifiedSha), launchProfileKey: launchProfileKey)
	}

	// MARK: - Post-initialize admits

	func testBoundIdentitySupportedFamilyIsFullAtStageThree() {
		let c = ClaudeAdmissionCoordinator(manifest: manifest([family()]))
		let eval = c.evaluatePostInitialize(postInit(), stage: .enforceAll)
		guard case .admitFull(let offered) = eval.decision else {
			return XCTFail("expected .admitFull, got \(eval.decision)")
		}
		XCTAssertEqual(eval.assessment.classification, .fullyCertified)
		XCTAssertFalse(offered.resume)          // §9.1.16
		XCTAssertFalse(offered.structuredOutput)
		XCTAssertTrue(offered.permissionModeRoundTrip)
	}

	func testBoundIdentityLimitedFamilyCarriesLimitedReasonAndText() {
		let c = ClaudeAdmissionCoordinator(manifest: manifest([family(classification: .limited)]))
		guard case .admitLimited(let reason, _, let limitations) =
				c.evaluatePostInitialize(postInit(), stage: .enforceLimited).decision else {
			return XCTFail("expected .admitLimited")
		}
		XCTAssertEqual(reason, .limitedClassification)
		XCTAssertEqual(limitations, ["family says limited"])   // exact, not tautology (finding 6)
	}

	// MARK: - Post-initialize rejects (fail-closed)

	func testUnboundIdentityFailsClosedNeverLimited() {
		// An unknown SHA has no exact match → behaviourUnavailable → reject under
		// enforcement. NEVER limited, NEVER fabricated a behaviour key (finding 1).
		let c = ClaudeAdmissionCoordinator(manifest: manifest([family()]))
		let q = postInit(sha: sha("f"))
		XCTAssertEqual(c.evaluatePostInitialize(q, stage: .observeOnly).decision, .admitUnrestricted)
		guard case .reject(.behaviorUnavailable) =
				c.evaluatePostInitialize(q, stage: .enforceKnownBad).decision else {
			return XCTFail("unbound identity must fail closed as behaviourUnavailable")
		}
		XCTAssertEqual(c.evaluatePostInitialize(q, stage: .observeOnly).assessment.classification,
					   .behaviorUnavailable)
	}

	func testEmptyManifestEverythingBehaviorUnavailable() {
		let c = ClaudeAdmissionCoordinator(manifest: .empty)
		guard case .reject(.behaviorUnavailable) =
				c.evaluatePostInitialize(postInit(), stage: .enforceKnownBad).decision else {
			return XCTFail("empty manifest → every identity behaviourUnavailable → reject")
		}
	}

	func testUnresolvableInertAtStageZeroRejectsUnderEnforcement() {
		let c = ClaudeAdmissionCoordinator(manifest: manifest([family()]))
		let q = ClaudePostInitializeQuery.unresolvable(.noPath)
		XCTAssertEqual(c.evaluatePostInitialize(q, stage: .observeOnly).decision, .admitUnrestricted)
		guard case .reject(.unresolvableIdentity(.noPath)) =
				c.evaluatePostInitialize(q, stage: .enforceKnownBad).decision else {
			return XCTFail("unresolvable must reject under enforcement")
		}
	}

	func testUncertifiedInterruptOnBoundFamilyRejectsNeverLimited() {
		let c = ClaudeAdmissionCoordinator(
			manifest: manifest([family(capabilities: capabilities(interrupt: .uncertified))]))
		guard case .reject(.uncertifiedInterrupt) =
				c.evaluatePostInitialize(postInit(), stage: .enforceLimited).decision else {
			return XCTFail("uncertified interrupt on a bound family must reject, not limit")
		}
	}

	func testValidationNotPerformedRejectsAtEveryEnforcementStage() {
		let c = ClaudeAdmissionCoordinator(manifest: manifest([family()]))
		let q = postInit(validation: .notPerformed)
		for stage in [ClaudeAdmissionEnforcementStage.enforceKnownBad, .enforceLimited, .enforceAll] {
			guard case .reject(.validationNotPerformed) = c.evaluatePostInitialize(q, stage: stage).decision else {
				return XCTFail(".notPerformed must reject at \(stage)")
			}
		}
		XCTAssertEqual(c.evaluatePostInitialize(q, stage: .observeOnly).decision, .admitUnrestricted)
	}

	func testValidationFailureRejectsOnlyAtStageThree() {
		let c = ClaudeAdmissionCoordinator(manifest: manifest([family()]))
		let q = postInit(validation: .failed(.permissionModeRoundTripFailed))
		guard case .admitFull = c.evaluatePostInitialize(q, stage: .enforceLimited).decision else {
			return XCTFail("stage 2 tolerates a known validation failure")
		}
		guard case .reject(.validationFailed(.permissionModeRoundTripFailed)) =
				c.evaluatePostInitialize(q, stage: .enforceAll).decision else {
			return XCTFail("stage 3 rejects a validation failure")
		}
	}

	func testExternalOnlyBoundIdentityRejectsEmbedded() {
		let c = ClaudeAdmissionCoordinator(manifest: manifest([family(classification: .externalOnly)]))
		guard case .admitUnrestricted = c.evaluatePostInitialize(postInit(), stage: .observeOnly).decision else {
			return XCTFail("stage 0 admits")
		}
		guard case .reject(.externalOnly) = c.evaluatePostInitialize(postInit(), stage: .enforceKnownBad).decision else {
			return XCTFail("external-only rejects embedded")
		}
	}

	// MARK: - Stage-0 inertness (finding 4)

	func testStageZeroDecisionIsUnrestrictedButAssessmentCarriesProjection() {
		let c = ClaudeAdmissionCoordinator(manifest: manifest([family()]))
		let eval = c.evaluatePostInitialize(postInit(), stage: .observeOnly)
		XCTAssertEqual(eval.decision, .admitUnrestricted)
		XCTAssertEqual(eval.assessment.classification, .fullyCertified)
		XCTAssertFalse(eval.assessment.offered.resume)
		XCTAssertTrue(eval.assessment.offered.permissionModeRoundTrip)
	}

	// MARK: - Known-bad on DERIVED keys (§9.1.3)

	func testKnownBadMatchesShaAxis() {
		let rule = ClaudeKnownBadRule(match: .sha256(certifiedSha), reason: "bad sha")
		let c = ClaudeAdmissionCoordinator(manifest: manifest([family()], knownBad: [rule]))
		guard case .reject(.knownBad("bad sha")) =
				c.evaluatePostInitialize(postInit(), stage: .enforceKnownBad).decision else {
			return XCTFail("sha axis must reject")
		}
	}

	func testKnownBadMatchesBoundFamilyBehaviorKeyAxis() {
		let rule = ClaudeKnownBadRule(match: .behaviorKey(behaviorKey), reason: "bad family")
		let c = ClaudeAdmissionCoordinator(manifest: manifest([family()], knownBad: [rule]))
		guard case .reject(.knownBad("bad family")) =
				c.evaluatePostInitialize(postInit(), stage: .enforceKnownBad).decision else {
			return XCTFail("behaviourKey axis must reject for a bound identity")
		}
	}

	func testKnownBadMatchesDerivedCertificationKeyAxis() {
		let rule = ClaudeKnownBadRule(match: .certificationKey(derivedCertificationKey), reason: "bad cert")
		let c = ClaudeAdmissionCoordinator(manifest: manifest([family()], knownBad: [rule]))
		guard case .reject(.knownBad("bad cert")) =
				c.evaluatePostInitialize(postInit(), stage: .enforceKnownBad).decision else {
			return XCTFail("derived certificationKey axis must reject")
		}
	}

	func testArbitraryCertificationKeyRuleDoesNotFire() {
		let rule = ClaudeKnownBadRule(match: .certificationKey(ClaudeCertificationKey(digest: sha("9"))), reason: "wrong cert")
		let c = ClaudeAdmissionCoordinator(manifest: manifest([family()], knownBad: [rule]))
		guard case .admitFull = c.evaluatePostInitialize(postInit(), stage: .enforceAll).decision else {
			return XCTFail("an arbitrary certification hash must not match")
		}
	}

	func testBehaviorAndCertKnownBadDoNotFireForUnboundIdentity() {
		// For an unbound identity only the SHA axis is decidable; behaviour/cert rules
		// cannot match (their digests are unavailable) — but the identity still fails
		// closed as behaviourUnavailable.
		let rules = [
			ClaudeKnownBadRule(match: .behaviorKey(behaviorKey), reason: "b"),
			ClaudeKnownBadRule(match: .certificationKey(derivedCertificationKey), reason: "c"),
		]
		let c = ClaudeAdmissionCoordinator(manifest: manifest([family()], knownBad: rules))
		guard case .reject(.behaviorUnavailable) =
				c.evaluatePostInitialize(postInit(sha: sha("f")), stage: .enforceKnownBad).decision else {
			return XCTFail("unbound identity fails closed regardless of behaviour/cert rules")
		}
	}

	func testKnownBadFiresWithTwoAxesDead() {
		let rules = [
			ClaudeKnownBadRule(match: .sha256(sha("0")), reason: "dead sha"),
			ClaudeKnownBadRule(match: .behaviorKey(ClaudeBehaviorKey(digest: sha("1"))), reason: "dead family"),
			ClaudeKnownBadRule(match: .certificationKey(derivedCertificationKey), reason: "live cert"),
		]
		let c = ClaudeAdmissionCoordinator(manifest: manifest([family()], knownBad: rules))
		guard case .reject(.knownBad("live cert")) =
				c.evaluatePostInitialize(postInit(), stage: .enforceKnownBad).decision else {
			return XCTFail("only the live certificationKey rule should fire")
		}
	}

	func testKnownBadPrecedenceOverFullCertification() {
		let rule = ClaudeKnownBadRule(match: .sha256(certifiedSha), reason: "revoked")
		let c = ClaudeAdmissionCoordinator(manifest: manifest([family()], knownBad: [rule]))
		guard case .reject(.knownBad("revoked")) =
				c.evaluatePostInitialize(postInit(), stage: .enforceAll).decision else {
			return XCTFail("known-bad must win over full certification")
		}
		XCTAssertEqual(c.evaluatePostInitialize(postInit(), stage: .observeOnly).decision, .admitUnrestricted)
	}

	// MARK: - §9.1.16 positive control

	func testProjectionOffersCertifiedCapability() {
		let c = ClaudeAdmissionCoordinator(
			manifest: manifest([family(capabilities: capabilities(resume: .certified))]))
		guard case .admitFull(let offered) =
				c.evaluatePostInitialize(postInit(), stage: .enforceAll).decision else {
			return XCTFail("expected admitFull")
		}
		XCTAssertTrue(offered.resume)
		XCTAssertFalse(offered.structuredOutput)
	}

	// MARK: - Phase split (finding 1)

	func testValidationGateIsPostInitializeOnly() {
		// Pre-launch has no validation concept; a bound identity admits provisionally.
		// Post-initialize applies the §3.1 gate: `.notPerformed` rejects.
		let c = ClaudeAdmissionCoordinator(manifest: manifest([family()]))
		XCTAssertEqual(c.evaluatePrelaunch(prelaunch(), stage: .enforceAll).decision, .admitFull(
			ClaudeOfferedCapabilities.project(family())))
		guard case .reject(.validationNotPerformed) =
				c.evaluatePostInitialize(postInit(validation: .notPerformed), stage: .enforceAll).decision else {
			return XCTFail("post-initialize gates on §3.1 validation")
		}
	}

	func testPrelaunchBoundIdentityAppliesProjectionAtStageTwo() {
		let c = ClaudeAdmissionCoordinator(manifest: manifest([family()]))
		XCTAssertEqual(c.evaluatePrelaunch(prelaunch(), stage: .observeOnly).decision, .admitUnrestricted)
		XCTAssertEqual(c.evaluatePrelaunch(prelaunch(), stage: .enforceKnownBad).decision, .admitUnrestricted)
		guard case .admitFull(let offered) = c.evaluatePrelaunch(prelaunch(), stage: .enforceLimited).decision else {
			return XCTFail("stage 2 applies the family projection to pre-spawn knobs")
		}
		XCTAssertFalse(offered.resume)
	}

	func testPrelaunchUnboundFailsClosedUnderEnforcement() {
		let c = ClaudeAdmissionCoordinator(manifest: manifest([family()]))
		let q = prelaunch(sha: sha("f"))
		XCTAssertEqual(c.evaluatePrelaunch(q, stage: .observeOnly).decision, .admitUnrestricted)
		guard case .reject(.behaviorUnavailable) = c.evaluatePrelaunch(q, stage: .enforceKnownBad).decision else {
			return XCTFail("unbound pre-launch identity must fail closed, not spawn")
		}
	}

	func testPrelaunchKnownBadByShaRejectsBeforeSpawn() {
		let rule = ClaudeKnownBadRule(match: .sha256(certifiedSha), reason: "revoked")
		let c = ClaudeAdmissionCoordinator(manifest: manifest([family()], knownBad: [rule]))
		XCTAssertEqual(c.evaluatePrelaunch(prelaunch(), stage: .observeOnly).decision, .admitUnrestricted)
		guard case .reject(.knownBad("revoked")) =
				c.evaluatePrelaunch(prelaunch(), stage: .enforceKnownBad).decision else {
			return XCTFail("sha known-bad rejects pre-spawn")
		}
	}

	func testPrelaunchUnresolvableRejectsUnderEnforcement() {
		let c = ClaudeAdmissionCoordinator(manifest: manifest([family()]))
		let q = ClaudePrelaunchQuery.unresolvable(.noPath)
		XCTAssertEqual(c.evaluatePrelaunch(q, stage: .observeOnly).decision, .admitUnrestricted)
		guard case .reject(.unresolvableIdentity(.noPath)) =
				c.evaluatePrelaunch(q, stage: .enforceKnownBad).decision else {
			return XCTFail("unresolvable rejects pre-spawn under enforcement")
		}
	}

	// MARK: - Ambiguous binding (#2): order-independent fail-closed

	func testAmbiguousBindingFailsClosedRegardlessOfFamilyOrder() {
		// The runtime decoder enforces uniqueness, but an in-process manifest can carry
		// the same identity in two families. Whichever order they appear, the result
		// must be the SAME fail-closed decision — array order must never decide.
		let supported = family(classification: .supported)
		let external = family(classification: .externalOnly) // same certifiedSha + launchProfileKey
		for families in [[supported, external], [external, supported]] {
			let c = ClaudeAdmissionCoordinator(manifest: manifest(families))
			guard case .reject(.ambiguousBinding) =
					c.evaluatePostInitialize(postInit(), stage: .enforceKnownBad).decision else {
				return XCTFail("ambiguous binding must fail closed regardless of order")
			}
			// Stage 0 stays inert.
			XCTAssertEqual(c.evaluatePostInitialize(postInit(), stage: .observeOnly).decision,
						   .admitUnrestricted)
		}
	}
}
