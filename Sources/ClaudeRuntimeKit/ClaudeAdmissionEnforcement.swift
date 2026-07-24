import Foundation

// Item 6 — the enforcement stage and the PURE §7.1 precedence resolver.
//
// The stage vocabulary is shared with the coordinator (item 5). The layers that
// SOURCE a stage — a DEBUG-only setter, a managed `UserDefaults` override, and the
// build-time shipping constant — are app-side, because each reads app state the
// pure core must not. What lives here is the ordering and the fail-safe: given the
// already-read layer values, which stage wins, and how absent or malformed input
// is handled.

/// The four rollout stages, ordered. Comparable so callers can ask "stage ≥ 1".
public enum ClaudeAdmissionEnforcementStage: Int, Hashable, Sendable, CaseIterable, Comparable {
	/// Compute everything, emit telemetry, ALWAYS admit full. No provisional profile.
	case observeOnly = 0
	/// Reject known-bad, external-only, uncertified interrupt, unresolvable identity.
	case enforceKnownBad = 1
	/// + `limited` disables §5.3 and applies the §5.1 provisional profile.
	case enforceLimited = 2
	/// + validation failure rejects.
	case enforceAll = 3

	public static func < (lhs: ClaudeAdmissionEnforcementStage,
						   rhs: ClaudeAdmissionEnforcementStage) -> Bool {
		lhs.rawValue < rhs.rawValue
	}

	/// Parse a stage from a stringly-typed override value (a `UserDefaults` string,
	/// an MDM value, or a DEBUG setter). Accepts the case name or the integer
	/// rawValue as a string. Anything else — including out-of-range integers — is
	/// `nil`. The app-side reader maps that `nil` to `ClaudeEnforcementOverride`
	/// `.malformed` (distinct from an unset key's `.absent`), which the resolver fails
	/// safe from rather than falling through. Never throws: a malformed override must
	/// not crash the launch path.
	public init?(overrideValue raw: String) {
		let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
		switch trimmed {
		case "observeOnly", "0": self = .observeOnly
		case "enforceKnownBad", "1": self = .enforceKnownBad
		case "enforceLimited", "2": self = .enforceLimited
		case "enforceAll", "3": self = .enforceAll
		default: return nil
		}
	}
}

/// One override layer's read. `.absent` and `.malformed` are DISTINCT: absence
/// yields to the next layer, malformed fails safe immediately. Collapsing them into
/// a single `nil` was the finding-5 defect — after a build-time promotion, a
/// malformed value would inherit the raised stage by falling through.
public enum ClaudeEnforcementOverride: Hashable, Sendable {
	/// The layer was not set. Follows precedence — yield to the next layer.
	case absent
	case valid(ClaudeAdmissionEnforcementStage)
	/// The layer was set to something unparseable (garbage, out-of-range, or the
	/// wrong type — e.g. a boolean). Resolves fail-safe to `.observeOnly`.
	case malformed
}

/// The PURE §7.1 precedence resolver. Highest precedence first:
///
/// 1. DEBUG-only setter — developer override; absent in Release.
/// 2. Managed/internal override — the rollback lever.
/// 3. Build-time shipping constant — compile-time, raised in a distinct commit.
/// 4. Fail-safe default — `.observeOnly`.
///
/// The FIRST layer that is not `.absent` decides: `.valid` yields its stage,
/// `.malformed` yields `.observeOnly` WITHOUT falling through. A malformed override
/// can therefore never raise enforcement, and it never lets a lower layer (or a
/// raised build-time constant) do so on its behalf. There is no migration-written
/// default, so an absent managed key stays unambiguously "never set".
public enum ClaudeAdmissionEnforcementResolution {
	public static func resolve(
		debug: ClaudeEnforcementOverride,
		managed: ClaudeEnforcementOverride,
		buildTimeShipping: ClaudeAdmissionEnforcementStage
	) -> ClaudeAdmissionEnforcementStage {
		for override in [debug, managed] {
			switch override {
			case .absent:
				continue
			case .valid(let stage):
				return stage
			case .malformed:
				return .observeOnly
			}
		}
		return buildTimeShipping
	}
}
