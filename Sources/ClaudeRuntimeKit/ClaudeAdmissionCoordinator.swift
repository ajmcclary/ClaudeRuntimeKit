import Foundation

// Item 5 — the single classification owner: the pure §4.8 decision engine.
//
// Placement in the pure core does NOT by itself make this the sole owner of
// classification (R15c); item 7's boundary gate proves that no other type branches
// on classification.
//
// EXACT-IDENTITY-ONLY ADMISSION (product decision, 2026-07-21). A runtime behaviour
// key is UNAVAILABLE pre-turn — `system/init` (the only carrier of
// `observedCapabilities`) is not emitted until a user message begins, and there is
// no production `helpFlagSet` producer (its only source, `claude --help`, is a
// second process the one-child contract forbids). Admission is therefore based
// solely on observable pre-turn evidence:
//   • An EXACT identity match — the runtime's binary SHA and launch-profile key
//     equal a `certifiedIdentity` in the manifest — BINDS the runtime to that
//     record's family (a manifest fact, not version inference).
//   • Anything else is `behaviourUnavailable`: its family cannot be established
//     pre-turn, so it fails closed under enforcement (external-only), never
//     fabricated a key, never spawned-then-retroactively-admitted.
// There is no `locallyValidated` grant and no behaviour-family match for an unknown
// SHA; those plan commitments were removed because they are impossible under the
// one-child contract. A newly installed Claude binary stays external-only under
// enforcement until its exact SHA and launch profile are certified by a manifest
// update. Stage 0 stays fully inert so uncertified releases can still be observed
// and taken through the deliberate certification pipeline.
//
// Other invariants: enum queries make the resolved/unresolvable pairing structural;
// only post-initialize carries the §3.1 validation gate (`.notPerformed` never
// satisfies the final decision at stage ≥ 1); keys are typed end-to-end so the
// behaviour and launch-profile axes cannot be swapped; interrupt is sourced from
// the bound family (an unbound runtime fails closed, never `limited`).

// MARK: - Phase inputs (structural resolved/unresolvable pairing)

/// Pre-launch (phase A). Only identity + launch-profile key exist.
public enum ClaudePrelaunchQuery: Sendable {
	case resolved(identity: ClaudeRuntimeIdentity, launchProfileKey: ClaudeLaunchProfileKey)
	case unresolvable(ClaudeRuntimeUnresolvableReason)
}

/// Post-initialize (phase B). Adds the §3.1 validation outcome. Still no behaviour
/// key (unavailable pre-turn).
public enum ClaudePostInitializeQuery: Sendable {
	case resolved(identity: ClaudeRuntimeIdentity, launchProfileKey: ClaudeLaunchProfileKey,
				  validation: ClaudeBehavioralValidationOutcome)
	case unresolvable(ClaudeRuntimeUnresolvableReason)
}

// MARK: - Per-capability projection (§9.1.16)

/// What a bound family OFFERS after per-capability state is applied. Interrupt is
/// absent: it is a safety PRECONDITION (§3.2), expressed as reject/admit.
public struct ClaudeOfferedCapabilities: Hashable, Sendable {
	public let models: [String]
	public let effortLevels: [String]
	public let structuredOutput: Bool
	public let resume: Bool
	public let permissionModeRoundTrip: Bool

	public init(models: [String], effortLevels: [String], structuredOutput: Bool,
				resume: Bool, permissionModeRoundTrip: Bool) {
		self.models = models
		self.effortLevels = effortLevels
		self.structuredOutput = structuredOutput
		self.resume = resume
		self.permissionModeRoundTrip = permissionModeRoundTrip
	}

	/// Nothing offered — for an unbound runtime (which fails closed under enforcement).
	public static let none = ClaudeOfferedCapabilities(
		models: [], effortLevels: [], structuredOutput: false,
		resume: false, permissionModeRoundTrip: false)

	/// Offer a capability iff the family certifies it (§9.1.16).
	public static func project(_ family: ClaudeManifestFamily) -> ClaudeOfferedCapabilities {
		ClaudeOfferedCapabilities(
			models: family.capabilities.models,
			effortLevels: family.capabilities.effortLevels,
			structuredOutput: family.capabilities.structuredOutput.state == .certified,
			resume: family.capabilities.resume.state == .certified,
			permissionModeRoundTrip: family.capabilities.permissionModeRoundTrip)
	}
}

// MARK: - Classification, assessment, decision

public enum ClaudeMatchedClassification: Hashable, Sendable {
	case fullyCertified              // bound identity, supported family
	case limitedBoundIdentity        // bound identity, limited family
	case externalOnlyBoundIdentity   // bound identity, external-only family
	/// No exact identity match — the behaviour family cannot be established pre-turn.
	case behaviorUnavailable
	/// More than one family bound this exact identity. Uniqueness is enforced at
	/// decode; this is a defensive, order-independent fail-closed for any manifest
	/// constructed in-process.
	case ambiguousBinding
	case knownBad(reason: String)
	case unresolvable(ClaudeRuntimeUnresolvableReason)
}

public struct ClaudeAdmissionAssessment: Hashable, Sendable {
	public let classification: ClaudeMatchedClassification
	/// The interrupt state of the bound family, or `.uncertified` when there is no
	/// unique bound family.
	public let interrupt: ClaudeCapabilityState
	/// The conservative per-capability projection, FOR TELEMETRY. Never the effective
	/// stage-0 policy (finding 4).
	public let offered: ClaudeOfferedCapabilities
	public let limitations: [String]

	public init(classification: ClaudeMatchedClassification, interrupt: ClaudeCapabilityState,
				offered: ClaudeOfferedCapabilities, limitations: [String]) {
		self.classification = classification
		self.interrupt = interrupt
		self.offered = offered
		self.limitations = limitations
	}
}

/// The only downgrade path is a bound identity in a `limited` family (whose own
/// `limitations` text the schema requires to be non-empty), so a limited admission
/// always has a user-visible cause.
public enum ClaudeLimitedAdmissionReason: Hashable, Sendable {
	case limitedClassification
}

public enum ClaudeAdmissionRejectReason: Hashable, Sendable {
	case knownBad(String)
	case unresolvableIdentity(ClaudeRuntimeUnresolvableReason)
	case externalOnly
	/// A BOUND family whose interrupt capability is uncertified.
	case uncertifiedInterrupt
	/// No bound family: the behaviour family cannot be established pre-turn.
	case behaviorUnavailable
	/// More than one family bound this identity — fail closed.
	case ambiguousBinding
	/// The final post-initialize decision was asked to admit without §3.1 having run.
	case validationNotPerformed
	case validationFailed(ClaudeBehavioralValidationFailure)
}

public enum ClaudeAdmissionDecision: Hashable, Sendable {
	/// Requested behaviour preserved, no provisional restriction. Stage 0 always;
	/// stage 1 when not rejected.
	case admitUnrestricted
	/// Bound + certified at stage ≥ 2: offers only the family's certified capabilities.
	case admitFull(ClaudeOfferedCapabilities)
	/// A bound identity in a `limited` family at stage ≥ 2.
	case admitLimited(reason: ClaudeLimitedAdmissionReason,
					  offered: ClaudeOfferedCapabilities, limitations: [String])
	/// Embedded admission refused; the runtime may still be operated externally.
	case reject(ClaudeAdmissionRejectReason)
}

/// The effective `decision` plus the telemetry `assessment`, returned together so
/// item 7 records §8 telemetry without a second call.
public struct ClaudeAdmissionEvaluation: Hashable, Sendable {
	public let assessment: ClaudeAdmissionAssessment
	public let decision: ClaudeAdmissionDecision

	public init(assessment: ClaudeAdmissionAssessment, decision: ClaudeAdmissionDecision) {
		self.assessment = assessment
		self.decision = decision
	}
}

// MARK: - Coordinator

public struct ClaudeAdmissionCoordinator: Sendable {
	public let manifest: ClaudeCompatibilityManifest

	public init(manifest: ClaudeCompatibilityManifest) {
		self.manifest = manifest
	}

	// MARK: Pre-launch (phase A) — provisional, no validation

	public func evaluatePrelaunch(_ query: ClaudePrelaunchQuery,
								  stage: ClaudeAdmissionEnforcementStage) -> ClaudeAdmissionEvaluation {
		let assessment: ClaudeAdmissionAssessment
		switch query {
		case .unresolvable(let reason):
			assessment = Self.unresolvableAssessment(reason)
		case .resolved(let identity, let launchProfileKey):
			assessment = assessResolved(sha: identity.sha256, launchProfileKey: launchProfileKey)
		}
		return ClaudeAdmissionEvaluation(
			assessment: assessment,
			decision: decide(assessment, validation: .notPerformed, gateValidation: false, stage: stage))
	}

	// MARK: Post-initialize (phase B) — final, §3.1 validation gate

	public func evaluatePostInitialize(_ query: ClaudePostInitializeQuery,
									   stage: ClaudeAdmissionEnforcementStage) -> ClaudeAdmissionEvaluation {
		let assessment: ClaudeAdmissionAssessment
		let validation: ClaudeBehavioralValidationOutcome
		switch query {
		case .unresolvable(let reason):
			assessment = Self.unresolvableAssessment(reason)
			validation = .notPerformed
		case .resolved(let identity, let launchProfileKey, let outcome):
			assessment = assessResolved(sha: identity.sha256, launchProfileKey: launchProfileKey)
			validation = outcome
		}
		return ClaudeAdmissionEvaluation(
			assessment: assessment,
			decision: decide(assessment, validation: validation, gateValidation: true, stage: stage))
	}

	/// Stage-independent classification from the binary SHA and launch-profile key
	/// alone. Known-bad has precedence over the bound-family admit.
	public func assess(_ query: ClaudePostInitializeQuery) -> ClaudeAdmissionAssessment {
		switch query {
		case .unresolvable(let reason):
			return Self.unresolvableAssessment(reason)
		case .resolved(let identity, let launchProfileKey, _):
			return assessResolved(sha: identity.sha256, launchProfileKey: launchProfileKey)
		}
	}

	private func assessResolved(sha: ClaudeSHA256,
								launchProfileKey: ClaudeLaunchProfileKey) -> ClaudeAdmissionAssessment {
		// All families binding this exact identity. Uniqueness is enforced at decode,
		// but detect multiple matches defensively and fail closed (order-independent).
		let bindings = manifest.families.filter { candidate in
			candidate.certifiedIdentities.contains {
				$0.sha256 == sha && $0.launchProfileKey == launchProfileKey
			}
		}
		let boundFamily = bindings.count == 1 ? bindings.first : nil

		// Behaviour/certification axes are decidable only for a UNIQUE bound family;
		// they are typed, so the coordinator can never compare the wrong axis.
		let behaviorKey = boundFamily?.behaviorKey
		let certificationKey = boundFamily.map {
			ClaudeCertificationKey(input: ClaudeCertificationKeyInput(
				binarySHA256: sha, behaviorKey: $0.behaviorKey, launchProfileKey: launchProfileKey))
		}

		// Known-bad precedence.
		for rule in manifest.knownBadRules where Self.matches(
			rule.match, sha: sha, behavior: behaviorKey, certification: certificationKey) {
			return ClaudeAdmissionAssessment(
				classification: .knownBad(reason: rule.reason), interrupt: .uncertified,
				offered: .none, limitations: [rule.reason])
		}

		if bindings.count > 1 {
			return Self.simpleAssessment(.ambiguousBinding)
		}
		guard let family = boundFamily else {
			return Self.simpleAssessment(.behaviorUnavailable)
		}

		let interrupt = family.capabilities.interrupt.state
		let classification: ClaudeMatchedClassification
		switch family.classification {
		case .externalOnly: classification = .externalOnlyBoundIdentity
		case .limited: classification = .limitedBoundIdentity
		case .supported: classification = .fullyCertified
		}
		return ClaudeAdmissionAssessment(
			classification: classification, interrupt: interrupt,
			offered: ClaudeOfferedCapabilities.project(family), limitations: family.limitations)
	}

	private func decide(_ assessment: ClaudeAdmissionAssessment,
						validation: ClaudeBehavioralValidationOutcome,
						gateValidation: Bool,
						stage: ClaudeAdmissionEnforcementStage) -> ClaudeAdmissionDecision {
		// Stage 0 — inert: preserve the complete requested behaviour. The conservative
		// projection lives only in the assessment (finding 4).
		if stage == .observeOnly { return .admitUnrestricted }

		switch assessment.classification {
		case .unresolvable(let reason):
			return .reject(.unresolvableIdentity(reason))
		case .knownBad(let reason):
			return .reject(.knownBad(reason))
		case .externalOnlyBoundIdentity:
			return .reject(.externalOnly)
		case .behaviorUnavailable:
			return .reject(.behaviorUnavailable)
		case .ambiguousBinding:
			return .reject(.ambiguousBinding)
		case .fullyCertified, .limitedBoundIdentity:
			if assessment.interrupt != .certified {
				return .reject(.uncertifiedInterrupt)
			}
			// §3.1 is a POST-INITIALIZE gate only. `.notPerformed` never satisfies the
			// final decision at stage ≥ 1; a KNOWN `.failed` is gated only at stage 3.
			if gateValidation {
				switch validation {
				case .notPerformed:
					return .reject(.validationNotPerformed)
				case .failed(let failure):
					if stage == .enforceAll { return .reject(.validationFailed(failure)) }
				case .passed:
					break
				}
			}
			if stage == .enforceKnownBad { return .admitUnrestricted }
			switch assessment.classification {
			case .fullyCertified:
				return .admitFull(assessment.offered)
			default: // .limitedBoundIdentity
				return .admitLimited(reason: .limitedClassification,
									 offered: assessment.offered, limitations: assessment.limitations)
			}
		}
	}

	private static func unresolvableAssessment(
		_ reason: ClaudeRuntimeUnresolvableReason
	) -> ClaudeAdmissionAssessment {
		simpleAssessment(.unresolvable(reason))
	}

	private static func simpleAssessment(
		_ classification: ClaudeMatchedClassification
	) -> ClaudeAdmissionAssessment {
		ClaudeAdmissionAssessment(classification: classification, interrupt: .uncertified,
								  offered: .none, limitations: [])
	}

	/// A behaviour/certification axis is decidable only for a unique bound identity;
	/// otherwise the digests are `nil` and only the SHA axis can match. Typed axes
	/// mean a rule authored for one axis can never match another.
	private static func matches(_ match: ClaudeKnownBadMatch, sha: ClaudeSHA256,
								behavior: ClaudeBehaviorKey?, certification: ClaudeCertificationKey?) -> Bool {
		switch match {
		case .sha256(let hash): return hash == sha
		case .behaviorKey(let key): return behavior == key
		case .certificationKey(let key): return certification == key
		}
	}
}

// MARK: - Durable cache tokens

/// Stable tokens for the exact-identity compatibility cache (plan §1.3, item 11).
///
/// These live HERE, with the classification, for two reasons. The coordinator is the
/// sole owner of classification semantics, so a consumer that switched over the cases
/// to build its own token would be a second place that decides what a classification
/// means — exactly what R15c forbids. And a durable record needs a token that is
/// stable across refactors of the enum: a case rename must be a deliberate schema
/// decision made here, not a silent change in what a stored record means.
///
/// The tokens are deliberately NOT the case names. They describe what was cached —
/// an exact-identity outcome — rather than restating the classification vocabulary.
extension ClaudeMatchedClassification {
	public var durableCacheToken: String {
		switch self {
		case .fullyCertified: return "exactCertified"
		case .limitedBoundIdentity: return "exactLimited"
		case .externalOnlyBoundIdentity: return "exactExternalOnly"
		case .behaviorUnavailable: return "noExactMatch"
		case .ambiguousBinding: return "ambiguousIdentity"
		case .knownBad: return "knownBadMatch"
		case .unresolvable: return "identityUnresolvable"
		}
	}
}

extension ClaudeBehavioralValidationOutcome {
	public var durableCacheToken: String {
		switch self {
		case .notPerformed: return "notObserved"
		case .passed: return "observedPassed"
		case .failed: return "observedFailed"
		}
	}
}
