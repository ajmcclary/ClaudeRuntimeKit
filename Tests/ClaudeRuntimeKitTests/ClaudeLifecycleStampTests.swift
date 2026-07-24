import XCTest
@testable import ClaudeRuntimeKit

/// Program A Slice 4b, step 3 — generation stamping at ingress.
///
/// DESIRED-BEHAVIOR tests.
///
/// Two independent coordinates, each with exactly one job:
///
///   - `ClaudeTransportEpoch` — bumped when the transport is (re)established.
///     A stamped input whose epoch is older than the current one is a replay
///     from a dead process, which is what the reconciler's `.ignoreReplay`
///     decision exists for.
///   - `ClaudeTurnGeneration` — names one opened turn, so an interrupt can say
///     WHICH turn it meant. Characterization pinned the current controller-wide
///     Boolean landing on whichever result arrived first; a generation-targeted
///     interrupt is how that stops being possible.
///
/// Host signals (interrupt, shutdown, transport close, idle fallback, reconnect)
/// are lifecycle inputs in their own right, not merely wire events. Shutdown in
/// particular must reach the reconciler BEFORE legacy state is cleared, which is
/// how the silently-dropped terminal status becomes observable at all.
final class ClaudeLifecycleStampTests: XCTestCase {

	// MARK: - Transport epoch

	func testEpochAdvancesOnlyWhenTheTransportIsReestablished() {
		var stamper = ClaudeLifecycleIngressStamper()
		let first = stamper.epoch

		let sameEpoch = stamper.stamp(.host(.idleFallbackFired))
		XCTAssertEqual(sameEpoch.epoch, first, "ordinary inputs must not advance the epoch")

		stamper.beginNewEpoch()
		XCTAssertGreaterThan(stamper.epoch, first, "reconnect/reinitialize advances the epoch")
	}

	/// The whole point of the epoch: a frame stamped before a reconnect stays
	/// stamped with the OLD epoch, so it is still recognizable as stale after the
	/// transport is replaced.
	func testAStampIsImmutableAndSurvivesALaterEpochChange() {
		var stamper = ClaudeLifecycleIngressStamper()
		let stampedBefore = stamper.stamp(.host(.transportClosed))
		let epochAtStampTime = stampedBefore.epoch

		stamper.beginNewEpoch()
		stamper.beginNewEpoch()

		XCTAssertEqual(
			stampedBefore.epoch,
			epochAtStampTime,
			"a stamp captured at ingress must not drift when the controller moves on"
		)
		XCTAssertLessThan(
			stampedBefore.epoch,
			stamper.epoch,
			"the older stamp must remain identifiable as belonging to a dead transport"
		)
	}

	func testEpochsAreOrdered() {
		var stamper = ClaudeLifecycleIngressStamper()
		let first = stamper.epoch
		stamper.beginNewEpoch()
		let second = stamper.epoch
		stamper.beginNewEpoch()
		let third = stamper.epoch

		XCTAssertLessThan(first, second)
		XCTAssertLessThan(second, third)
	}

	// MARK: - Turn generation

	func testEachOpenedTurnGetsADistinctIncreasingGeneration() {
		var stamper = ClaudeLifecycleIngressStamper()
		let first = stamper.openTurn()
		let second = stamper.openTurn()
		let third = stamper.openTurn()

		XCTAssertLessThan(first, second)
		XCTAssertLessThan(second, third)
		XCTAssertEqual(Set([first, second, third]).count, 3, "turn generations must be distinct")
	}

	/// Turn generations must not restart when the transport does, or an interrupt
	/// targeting a pre-reconnect turn could match a post-reconnect one.
	func testTurnGenerationsDoNotRestartAcrossEpochs() {
		var stamper = ClaudeLifecycleIngressStamper()
		let beforeReconnect = stamper.openTurn()
		stamper.beginNewEpoch()
		let afterReconnect = stamper.openTurn()

		XCTAssertGreaterThan(
			afterReconnect,
			beforeReconnect,
			"turn generations are globally monotonic so they can never collide across epochs"
		)
	}

	// MARK: - Host signals

	/// An interrupt names the generation it meant. This is the structural fix for
	/// the characterized defect where a controller-wide Boolean was consumed by
	/// whichever result landed first.
	func testInterruptSignalTargetsASpecificTurnGeneration() {
		var stamper = ClaudeLifecycleIngressStamper()
		_ = stamper.openTurn()
		let intended = stamper.openTurn()

		let stamped = stamper.stamp(.host(.interruptRequested(target: intended)))

		guard case .host(.interruptRequested(let target)) = stamped.input else {
			return XCTFail("expected an interrupt signal, got \(stamped.input)")
		}
		XCTAssertEqual(target, intended, "the interrupt must name the turn it was aimed at")
	}

	func testAllHostLifecycleSignalsAreStampableInputs() {
		var stamper = ClaudeLifecycleIngressStamper()
		let turn = stamper.openTurn()
		let signals: [ClaudeHostLifecycleSignal] = [
			.interruptRequested(target: turn),
			.idleFallbackFired,
			.transportClosed,
			.shutdownRequested,
			.transportReestablished
		]

		for signal in signals {
			let stamped = stamper.stamp(.host(signal))
			guard case .host(let recovered) = stamped.input else {
				return XCTFail("host signal \(signal) must round-trip as a host input")
			}
			XCTAssertEqual(recovered, signal, "host signal \(signal) must survive stamping unchanged")
		}
	}

	// MARK: - Wire inputs

	func testWireEventsAreStampedWithoutBeingAltered() {
		var stamper = ClaudeLifecycleIngressStamper()
		let event = ClaudeLifecycleEvent(
			phase: .resultObserved,
			identity: ClaudeLifecycleIdentity(sessionID: "s-1", messageID: "m-1", taskID: nil),
			scope: .topLevel
		)

		let stamped = stamper.stamp(.wire(event))

		guard case .wire(let recovered) = stamped.input else {
			return XCTFail("expected a wire input, got \(stamped.input)")
		}
		XCTAssertEqual(recovered, event, "stamping adds a generation; it must not rewrite the observation")
		XCTAssertEqual(
			recovered.identity.sessionID,
			"s-1",
			"observed session identity must survive to the reconciler as corroboration"
		)
	}

	// MARK: - Structural constraints

	/// A stamped input carries the epoch and the observation. If an app turn ID
	/// ever appears here, ingress has started resolving identity — which is the
	/// reconciler's job, not the stamper's.
	func testStampedInputCarriesOnlyEpochAndInput() {
		var stamper = ClaudeLifecycleIngressStamper()
		let stamped = stamper.stamp(.host(.shutdownRequested))
		let fields = Set(Mirror(reflecting: stamped).children.compactMap(\.label))
		XCTAssertEqual(
			fields,
			["epoch", "input"],
			"a stamp is a generation plus an observation, nothing more; got \(fields)"
		)
	}
}
