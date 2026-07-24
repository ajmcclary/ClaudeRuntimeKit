import XCTest
@testable import ClaudeRuntimeKit

/// Slice 4b Task 0: provider-controlled lifecycle ordering must be
/// degraded-but-survivable, never process-fatal. The recorder is the single
/// owner of drift observation — it must be bounded, carry stable fingerprints,
/// and never carry a payload or an identifier.
final class ClaudeLifecycleDriftRecorderTests: XCTestCase {
	func testEveryDriftSiteHasAStableFingerprint() {
		for site in ClaudeLifecycleDrift.Site.allCases {
			let drift = ClaudeLifecycleDrift(site: site)
			XCTAssertFalse(drift.fingerprint.isEmpty)
			XCTAssertEqual(
				drift.fingerprint,
				ClaudeLifecycleDrift(site: site).fingerprint,
				"fingerprint must be stable across instances"
			)
		}
	}

	func testFingerprintsAreDistinctPerSite() {
		let fingerprints = ClaudeLifecycleDrift.Site.allCases.map {
			ClaudeLifecycleDrift(site: $0).fingerprint
		}
		XCTAssertEqual(Set(fingerprints).count, fingerprints.count, "sites must not collide")
	}

	/// The whole point: a drift record is an identity, not a payload. If an id or
	/// a payload could ride along, this becomes a leak channel like the raw-event
	/// log was.
	func testDriftCarriesNoPayloadAndNoIdentifiers() {
		let drift = ClaudeLifecycleDrift(site: .resultMessageStopWithoutPendingTurn)
		let mirror = Mirror(reflecting: drift)
		let fields = Set(mirror.children.compactMap(\.label))
		XCTAssertEqual(fields, ["site"], "drift must hold only its site; got \(fields)")
		// Summary and fingerprint are derived from identity only.
		for forbidden in ["turnID", "sessionID", "payload", "uuid"] {
			XCTAssertFalse(drift.summary.lowercased().contains(forbidden.lowercased()))
		}
	}

	func testRecorderCountsPerFingerprint() {
		let recorder = ClaudeLifecycleDriftRecorder()
		recorder.record(.resultMessageStopWithoutPendingTurn)
		recorder.record(.resultMessageStopWithoutPendingTurn)
		recorder.record(.duplicateResultForOpenTurn)

		let snapshot = recorder.snapshot()
		XCTAssertEqual(snapshot.totalCount, 3)
		XCTAssertEqual(snapshot.count(for: .resultMessageStopWithoutPendingTurn), 2)
		XCTAssertEqual(snapshot.count(for: .duplicateResultForOpenTurn), 1)
		XCTAssertEqual(snapshot.count(for: .completionForUnknownGeneration), 0)
	}

	/// Bounded: a pathological provider that drifts forever must not grow memory.
	func testRecorderIsBoundedAndKeepsCounting() {
		let recorder = ClaudeLifecycleDriftRecorder(perSiteCap: 5)
		for _ in 0..<1000 {
			recorder.record(.resultMessageStopWithoutPendingTurn)
		}
		let snapshot = recorder.snapshot()
		XCTAssertEqual(
			snapshot.count(for: .resultMessageStopWithoutPendingTurn), 5,
			"per-site count must saturate at the cap"
		)
		XCTAssertTrue(snapshot.saturatedSites.contains(.resultMessageStopWithoutPendingTurn))
		XCTAssertEqual(snapshot.observedCount(for: .resultMessageStopWithoutPendingTurn), 1000,
			"observed total keeps counting even while the retained count saturates")
	}

	func testEmptyRecorderReportsNoDrift() {
		let snapshot = ClaudeLifecycleDriftRecorder().snapshot()
		XCTAssertEqual(snapshot.totalCount, 0)
		XCTAssertTrue(snapshot.saturatedSites.isEmpty)
	}

	func testSnapshotIsAValueAndDoesNotTrackLaterRecords() {
		let recorder = ClaudeLifecycleDriftRecorder()
		recorder.record(.resultMessageStopWithoutPendingTurn)
		let snapshot = recorder.snapshot()
		recorder.record(.resultMessageStopWithoutPendingTurn)
		XCTAssertEqual(snapshot.totalCount, 1, "snapshot must be a value, not a live view")
	}
}
