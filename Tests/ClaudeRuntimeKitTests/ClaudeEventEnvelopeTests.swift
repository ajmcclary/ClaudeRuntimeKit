import XCTest
@testable import ClaudeRuntimeKit

/// Slice 1: lossless per-line envelope.
///
/// Every NDJSON line decodes into a `ClaudeEventEnvelope` that preserves the
/// raw bytes and surfaces stable identity fields (type, subtype, session ID,
/// request ID, parent tool-use ID, message ID, timestamp, binary version).
/// Non-object lines are non-decodable but still carry their raw bytes.
final class ClaudeEventEnvelopeTests: XCTestCase {
	private func envelope(_ line: String) -> ClaudeEventEnvelope {
		ClaudeEventEnvelope.decode(line: Data(line.utf8))
	}

	func testCapturesIdentityFromSystemInit() {
		let line = #"{"type":"system","subtype":"init","session_id":"sess-1","uuid":"u-1"}"#
		let env = envelope(line)

		XCTAssertTrue(env.isDecodable)
		XCTAssertEqual(env.type, "system")
		XCTAssertEqual(env.subtype, "init")
		XCTAssertEqual(env.sessionID, "sess-1")
		XCTAssertEqual(env.messageID, "u-1")
		XCTAssertEqual(env.rawBytes, Data(line.utf8))
	}

	func testCapturesNestedMessageID() {
		let line = #"{"type":"assistant","message":{"id":"msg_123","role":"assistant","content":[]}}"#
		XCTAssertEqual(envelope(line).messageID, "msg_123")
	}

	func testCapturesRequestParentToolAndTimestamp() {
		let line = #"{"type":"stream_event","request_id":"req-9","parent_tool_use_id":"toolu_p","timestamp":"2026-07-18T00:00:00Z","event":{"type":"message_stop"}}"#
		let env = envelope(line)

		XCTAssertEqual(env.requestID, "req-9")
		XCTAssertEqual(env.parentToolUseID, "toolu_p")
		XCTAssertEqual(env.timestamp, "2026-07-18T00:00:00Z")
	}

	func testCapturesBinaryVersionWhenPresent() {
		let line = #"{"type":"system","subtype":"init","version":"1.2.3"}"#
		XCTAssertEqual(envelope(line).binaryVersion, "1.2.3")
	}

	func testAbsentIdentityFieldsAreNil() {
		let env = envelope(#"{"type":"result"}"#)

		XCTAssertTrue(env.isDecodable)
		XCTAssertEqual(env.type, "result")
		XCTAssertNil(env.subtype)
		XCTAssertNil(env.sessionID)
		XCTAssertNil(env.requestID)
		XCTAssertNil(env.parentToolUseID)
		XCTAssertNil(env.messageID)
		XCTAssertNil(env.timestamp)
		XCTAssertNil(env.binaryVersion)
	}

	func testMalformedLineIsNonDecodableButPreservesRawBytes() {
		let line = "this is not json"
		let env = envelope(line)

		XCTAssertFalse(env.isDecodable)
		XCTAssertNil(env.json)
		XCTAssertNil(env.type)
		XCTAssertEqual(env.rawBytes, Data(line.utf8))
	}

	func testJSONArrayLineIsNonDecodable() {
		let line = "[1,2,3]"
		let env = envelope(line)

		// The translator only ever handled JSON objects; an array line is not a
		// decodable event, but its raw bytes are still preserved for diagnostics.
		XCTAssertFalse(env.isDecodable)
		XCTAssertEqual(env.rawBytes, Data(line.utf8))
	}

	func testEmptyLineIsNonDecodable() {
		XCTAssertFalse(envelope("").isDecodable)
		XCTAssertFalse(envelope("   ").isDecodable)
	}
}
