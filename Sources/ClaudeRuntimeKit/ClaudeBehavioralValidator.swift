import Foundation

// Item 5, §3.1 — behavioural validation, expressed as a PURE observation over
// results the production child has ALREADY produced at the post-initialize point,
// BEFORE the first user message.
//
// CRITICAL SEQUENCING (item-2 canary): only the `initialize` control RESPONSE is
// available at this point. Its fields are account, agents, available_output_styles,
// commands, models, output_style, pid, and related — but NO `capabilities` and NO
// `session_id`. `session_id` first appears in `system/init`, which is emitted only
// AFTER a user message begins. So §3.1 cannot require a session id, and cannot
// require `system/init`; either would either deadlock (`startOrResume` must return
// before a message can be sent) or reject every certified fresh launch.
//
// §3.1 therefore validates exactly what IS observable pre-turn:
//   1. the `initialize` control response is well formed, and
//   2. the existing post-initialize `set_permission_mode` control request (`:850`)
//      round-tripped.
//
// This type performs no I/O. It must not launch a second process, add a timeout,
// send a duplicate permission request, or re-read `config.permissionMode`; the
// controller feeds it the values it already obtained.
//
// What it establishes is PROTOCOL LIVENESS, not capability — nothing about resume,
// nothing about interrupt. A session id, and `system/init`'s `observedCapabilities`,
// are post-turn DIAGNOSTIC-ONLY signals, never a pre-turn admission gate. Callers
// must not read a `.passed` outcome as capability evidence.

public enum ClaudeBehavioralValidationFailure: Hashable, Sendable {
	/// The `initialize` control response was not well formed.
	case initializeNotWellFormed
	/// The existing `set_permission_mode` control request did not round-trip.
	case permissionModeRoundTripFailed
}

public enum ClaudeBehavioralValidationOutcome: Hashable, Sendable {
	/// Phase A (pre-launch) has no initialized child yet, so validation has not run.
	/// Distinct from `.passed`: it must never satisfy a stage-≥1 final decision.
	case notPerformed
	case passed
	case failed(ClaudeBehavioralValidationFailure)
}

public enum ClaudeBehavioralValidator {
	/// Order is load-bearing: an ill-formed initialize response is reported before
	/// the permission round trip, so the FIRST thing that is wrong is the reason
	/// surfaced.
	///
	/// - Parameters:
	///   - initializeResponseWellFormed: whether the `initialize` control response —
	///     the frame actually available pre-turn — parsed and is structurally sound.
	///   - permissionModeRoundTripSucceeded: whether the existing post-initialize
	///     `set_permission_mode` control request round-tripped.
	public static func validate(
		initializeResponseWellFormed: Bool,
		permissionModeRoundTripSucceeded: Bool
	) -> ClaudeBehavioralValidationOutcome {
		guard initializeResponseWellFormed else { return .failed(.initializeNotWellFormed) }
		guard permissionModeRoundTripSucceeded else { return .failed(.permissionModeRoundTripFailed) }
		return .passed
	}
}
