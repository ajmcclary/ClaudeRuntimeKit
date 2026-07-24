import Foundation

/// Generation stamping for Claude lifecycle inputs (Slice 4b, ClaudeRuntimeCore).
///
/// Generation is HOST state. It cannot be inferred from a Claude payload and
/// must never be guessed from one, so it is captured at raw-frame ingress —
/// before translation, before any asynchronous dispatch — and is immutable
/// thereafter. A stamp taken before a reconnect keeps its original epoch, which
/// is the only reason a late frame from a dead transport is still recognizable
/// as stale.
///
/// Two coordinates, each with one job. Folding them into a single counter would
/// make "is this stale?" and "which turn did the interrupt mean?" the same
/// question, and they are not.

/// Transport generation. Advances when the transport is (re)established.
/// An input stamped with an older epoch than the current one is a replay.
public struct ClaudeTransportEpoch: Hashable, Comparable, Sendable {
	public let value: UInt64

	public init(value: UInt64) { self.value = value }

	public static let initial = ClaudeTransportEpoch(value: 0)

	public func next() -> ClaudeTransportEpoch {
		ClaudeTransportEpoch(value: value &+ 1)
	}

	public static func < (lhs: Self, rhs: Self) -> Bool { lhs.value < rhs.value }
}

/// Names one opened turn, so a host signal can say which turn it meant.
/// Globally monotonic — never restarted by a reconnect, or an interrupt aimed
/// at a pre-reconnect turn could match a post-reconnect one.
public struct ClaudeTurnGeneration: Hashable, Comparable, Sendable {
	public let value: UInt64

	public init(value: UInt64) { self.value = value }

	public static func < (lhs: Self, rhs: Self) -> Bool { lhs.value < rhs.value }
}

/// Lifecycle facts that originate in the host rather than on the wire.
///
/// These are first-class lifecycle inputs, not bookkeeping. `shutdownRequested`
/// especially: characterization pinned that `shutdown()` clears turn identities
/// before draining deferred statuses, dropping an already-observed terminal
/// status with no completion and no drift. Delivering shutdown to the
/// reconciler BEFORE legacy state is cleared is what makes that loss visible.
public enum ClaudeHostLifecycleSignal: Equatable, Sendable {
	/// An interrupt aimed at a specific turn. Targeting a generation rather than
	/// setting a controller-wide flag is the structural fix for the characterized
	/// defect where the flag was consumed by whichever result arrived first.
	case interruptRequested(target: ClaudeTurnGeneration)
	case idleFallbackFired
	/// Stdout EOF — the transport ended on its own.
	case transportClosed
	/// A deliberate host-initiated teardown.
	case shutdownRequested
	/// The protocol itself failed; the host is tearing the session down as a fault.
	///
	/// Distinct from `transportClosed`: EOF is the transport ending, this is the
	/// session ending because what came over it could not be honoured. Without this
	/// signal the `protocolFailure` completion trigger had no producer at all.
	case protocolFailureOccurred
	/// A new transport was established (reconnect / reinitialize).
	case transportReestablished
}

public enum ClaudeLifecycleInput: Equatable, Sendable {
	case wire(ClaudeLifecycleEvent)
	case host(ClaudeHostLifecycleSignal)
}

/// An observation plus the generation it was observed in. Both fields are `let`:
/// once ingress has stamped an input, nothing may restamp it.
public struct ClaudeStampedLifecycleInput: Equatable, Sendable {
	public let epoch: ClaudeTransportEpoch
	public let input: ClaudeLifecycleInput

	public init(epoch: ClaudeTransportEpoch, input: ClaudeLifecycleInput) {
		self.epoch = epoch
		self.input = input
	}
}

/// Owns the host's generation counters and stamps inputs at ingress.
///
/// A value type by design: the controller (an actor) owns exactly one instance,
/// so the counters need no locking, and R12 can ratchet that there is only one
/// owner.
public struct ClaudeLifecycleIngressStamper: Sendable {
	public private(set) var epoch: ClaudeTransportEpoch
	private var lastTurnGeneration: UInt64

	public init() {
		self.epoch = .initial
		self.lastTurnGeneration = 0
	}

	/// Advances the transport generation. Call when a process is launched or
	/// relaunched — never on an ordinary frame.
	public mutating func beginNewEpoch() {
		epoch = epoch.next()
	}

	/// Mints the generation for a newly opened turn.
	public mutating func openTurn() -> ClaudeTurnGeneration {
		lastTurnGeneration &+= 1
		return ClaudeTurnGeneration(value: lastTurnGeneration)
	}

	/// Captures the current epoch against an observation. The returned value is
	/// immutable; a later `beginNewEpoch()` does not affect stamps already taken.
	public func stamp(_ input: ClaudeLifecycleInput) -> ClaudeStampedLifecycleInput {
		ClaudeStampedLifecycleInput(epoch: epoch, input: input)
	}
}
