import XCTest
import Foundation
import ClaudeRuntimeKit

final class ClaudeSendableSnapshotTests: XCTestCase {
	private func requireSendable<T: Sendable>(_ value: T) {}

	func testRuntimeValuesHaveCheckedSendableConformances() {
		let envelope = ClaudeEventEnvelope.decode(line: Data(#"{"type":"future","unknown":true}"#.utf8))
		let diagnostic = ClaudeRuntimeDiagnostic.unknownEvent(from: envelope)
		var accumulator = ClaudeRuntimeDiagnosticAccumulator()
		accumulator.record(diagnostic)
		requireSendable(envelope)
		requireSendable(diagnostic)
		requireSendable(accumulator)
		requireSendable(ClaudePartialToolInputAssembler())
		requireSendable(ClaudeRuntimeEvent.assistantText(.init(messageID: "m", text: "text", extra: [:])))
	}

	func testEnvelopeTransfersRawBytesAndExactLargeIntegerAcrossTasks() async throws {
		let raw = Data("  {\"type\":\"future\",\"large\":9007199254740993,\"nested\":{\"flag\":true},\"unknown\":null}\n".utf8)
		let envelope = ClaudeEventEnvelope.decode(line: raw)
		let readings = await withTaskGroup(of: String?.self, returning: [String?].self) { group in
			for _ in 0..<20 {
				group.addTask { (envelope.json?["large"] as? NSNumber)?.stringValue }
			}
			var values: [String?] = []
			for await value in group { values.append(value) }
			return values
		}
		XCTAssertEqual(envelope.rawBytes, raw)
		XCTAssertEqual(readings, Array(repeating: "9007199254740993", count: 20))
		XCTAssertTrue(envelope.json?["unknown"] is NSNull)
		XCTAssertEqual((envelope.json?["nested"] as? [String: Bool])?["flag"], true)
	}

	func testDiagnosticKeepsRedactionAndUnknownFieldsAcrossMaterialization() {
		let raw = Data(#"{"type":"future","api_key":"fixture-secret","nested":{"large":9007199254740993,"authorization":"Bearer fixture-token"},"future":[true,null,2]}"#.utf8)
		let diagnostic = ClaudeRuntimeDiagnostic.unknownEvent(from: .decode(line: raw))
		let first = diagnostic.redactedPayload
		let second = diagnostic.redactedPayload
		XCTAssertEqual(first?["api_key"] as? String, ClaudeCredentialRedactor.placeholder)
		XCTAssertEqual((second?["nested"] as? [String: Any])?["authorization"] as? String, ClaudeCredentialRedactor.placeholder)
		XCTAssertEqual(((second?["nested"] as? [String: Any])?["large"] as? NSNumber)?.stringValue, "9007199254740993")
		XCTAssertEqual((second?["future"] as? [Any])?.count, 3)
		XCTAssertEqual(diagnostic.rawByteCount, raw.count)
	}

	func testMaterializedEnvelopeMutationDoesNotChangeLaterViewsOrIdentity() {
		let envelope = ClaudeEventEnvelope.decode(line: Data(#"{"type":"assistant","session_id":"original","message":{"id":"m1","text":"original"}}"#.utf8))
		var view = envelope.json!
		view["session_id"] = "changed"
		view["message"] = ["id": "changed", "text": "changed"]
		XCTAssertEqual(envelope.sessionID, "original")
		XCTAssertEqual(envelope.messageID, "m1")
		XCTAssertEqual(envelope.json?["session_id"] as? String, "original")
		XCTAssertEqual((envelope.json?["message"] as? [String: String])?["text"], "original")
	}
}
