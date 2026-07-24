import XCTest
@testable import ClaudeRuntimeKit

/// Slice 1: preserved diagnostics for unknown/malformed Claude events, and the
/// bounded, redacted accumulator the controller will own.
///
/// Diagnostics are counted by a STABLE fingerprint (invariant to variable
/// payload content), redacted by key, and sampled into a bounded store. They
/// never carry secrets in the summary and are never auto-converted to
/// user-facing errors (that is the controller's policy, tested at integration).
final class ClaudeRuntimeDiagnosticTests: XCTestCase {
	private func envelope(_ line: String) -> ClaudeEventEnvelope {
		ClaudeEventEnvelope.decode(line: Data(line.utf8))
	}

	// MARK: - Fingerprint stability

	func testUnknownEventFingerprintIsStableAcrossVariablePayload() {
		let a = ClaudeRuntimeDiagnostic.unknownEvent(from: envelope(
			#"{"type":"mystery","subtype":"x","seq":1,"nonce":"aaa"}"#))
		let b = ClaudeRuntimeDiagnostic.unknownEvent(from: envelope(
			#"{"type":"mystery","subtype":"x","seq":9999,"nonce":"zzz"}"#))

		XCTAssertEqual(a.fingerprint, b.fingerprint)
		XCTAssertEqual(a.kind, .unknownEvent)
	}

	func testUnknownEventFingerprintDiffersByTypeAndSubtype() {
		let base = ClaudeRuntimeDiagnostic.unknownEvent(from: envelope(#"{"type":"mystery","subtype":"x"}"#))
		let otherType = ClaudeRuntimeDiagnostic.unknownEvent(from: envelope(#"{"type":"other","subtype":"x"}"#))
		let otherSubtype = ClaudeRuntimeDiagnostic.unknownEvent(from: envelope(#"{"type":"mystery","subtype":"y"}"#))

		XCTAssertNotEqual(base.fingerprint, otherType.fingerprint)
		XCTAssertNotEqual(base.fingerprint, otherSubtype.fingerprint)
	}

	func testMalformedLineFingerprintIsStable() {
		let a = ClaudeRuntimeDiagnostic.malformedLine(from: envelope("not json at all"))
		let b = ClaudeRuntimeDiagnostic.malformedLine(from: envelope("also not json, different"))

		XCTAssertEqual(a.fingerprint, b.fingerprint)
		XCTAssertEqual(a.kind, .malformedLine)
		XCTAssertNil(a.redactedPayload)
	}

	// MARK: - Redaction

	func testUnknownEventRedactsSensitivePayloadAndKeepsSecretOutOfSummary() {
		let secret = "sk-ant-NEVER-LEAK-42"
		let diagnostic = ClaudeRuntimeDiagnostic.unknownEvent(from: envelope(
			#"{"type":"mystery","api_key":"\#(secret)","note":"visible"}"#))

		XCTAssertEqual(diagnostic.redactedPayload?["api_key"] as? String, ClaudeCredentialRedactor.placeholder)
		XCTAssertEqual(diagnostic.redactedPayload?["note"] as? String, "visible")
		XCTAssertFalse(diagnostic.summary.contains(secret))
		XCTAssertFalse(String(describing: diagnostic.redactedPayload).contains(secret))
	}

	func testMalformedToolInputDiagnosticExcludesRawBufferContent() {
		let secret = "sk-ant-IN-PARTIAL-JSON"
		let diagnostic = ClaudeRuntimeDiagnostic.malformedToolInput(
			messageID: "msg_1",
			blockIndex: 2,
			rawBuffer: #"{"api_key":"\#(secret)"#
		)

		XCTAssertEqual(diagnostic.kind, .malformedToolInput)
		XCTAssertNil(diagnostic.redactedPayload)
		XCTAssertFalse(diagnostic.summary.contains(secret))
		XCTAssertTrue(diagnostic.summary.contains("msg_1"))
	}

	// MARK: - Bounded accumulator

	func testAccumulatorCountsByFingerprintButSamplesOncePerFingerprint() {
		var accumulator = ClaudeRuntimeDiagnosticAccumulator(maxSamples: 8)
		let d = ClaudeRuntimeDiagnostic.unknownEvent(from: envelope(#"{"type":"mystery","subtype":"x"}"#))

		accumulator.record(d)
		accumulator.record(d)
		accumulator.record(d)

		XCTAssertEqual(accumulator.totalCount, 3)
		XCTAssertEqual(accumulator.count(for: d.fingerprint), 3)
		XCTAssertEqual(accumulator.samples.count, 1)
	}

	func testAccumulatorCapsDistinctSamplesButKeepsCounting() {
		var accumulator = ClaudeRuntimeDiagnosticAccumulator(maxSamples: 2)
		let a = ClaudeRuntimeDiagnostic.unknownEvent(from: envelope(#"{"type":"a"}"#))
		let b = ClaudeRuntimeDiagnostic.unknownEvent(from: envelope(#"{"type":"b"}"#))
		let c = ClaudeRuntimeDiagnostic.unknownEvent(from: envelope(#"{"type":"c"}"#))

		accumulator.record(a)
		accumulator.record(b)
		accumulator.record(c)

		XCTAssertEqual(accumulator.samples.count, 2, "distinct samples capped at maxSamples")
		XCTAssertEqual(accumulator.totalCount, 3)
		// Counts are complete even for fingerprints beyond the sample cap.
		XCTAssertEqual(accumulator.count(for: c.fingerprint), 1)
	}
}
