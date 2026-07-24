import XCTest
@testable import ClaudeRuntimeKit

/// Slice 1: assembly of streamed `input_json_delta` tool input, keyed by
/// message + block index, parsed only at block stop.
///
/// Covers interleaving, missing/duplicate start-stop, malformed completion,
/// cleanup, size limits, and the explicit reset points (block stop, message
/// stop / result, new message generation).
final class ClaudePartialToolInputAssemblerTests: XCTestCase {
	private func assembledInput(_ outcome: ClaudePartialToolInputAssembler.Outcome) -> [String: Any]? {
		guard case let .assembled(result) = outcome else { return nil }
		return result.input
	}

	// MARK: - Interleaving

	func testInterleavedBlocksAssembleIndependently() {
		var assembler = ClaudePartialToolInputAssembler()
		assembler.beginBlock(messageID: "m1", blockIndex: 0, toolUseID: "t0", toolName: "Bash")
		assembler.beginBlock(messageID: "m1", blockIndex: 1, toolUseID: "t1", toolName: "Read")
		_ = assembler.appendPartialJSON(messageID: "m1", blockIndex: 0, fragment: #"{"command":"#)
		_ = assembler.appendPartialJSON(messageID: "m1", blockIndex: 1, fragment: #"{"path":"#)
		_ = assembler.appendPartialJSON(messageID: "m1", blockIndex: 0, fragment: #""ls"}"#)
		_ = assembler.appendPartialJSON(messageID: "m1", blockIndex: 1, fragment: #""/tmp"}"#)

		let block0 = assembler.finishBlock(messageID: "m1", blockIndex: 0)
		let block1 = assembler.finishBlock(messageID: "m1", blockIndex: 1)

		XCTAssertEqual(assembledInput(block0)?["command"] as? String, "ls")
		XCTAssertEqual(assembledInput(block1)?["path"] as? String, "/tmp")
		if case let .assembled(result) = block0 {
			XCTAssertEqual(result.toolName, "Bash")
			XCTAssertEqual(result.toolUseID, "t0")
			XCTAssertEqual(result.blockIndex, 0)
		} else {
			XCTFail("block0 should assemble")
		}
		XCTAssertEqual(assembler.activeBlockCount, 0, "finished blocks are cleaned up")
	}

	// MARK: - Missing / duplicate start-stop

	func testMissingStartStillAssemblesWithNilToolIdentity() {
		var assembler = ClaudePartialToolInputAssembler()
		_ = assembler.appendPartialJSON(messageID: "m1", blockIndex: 0, fragment: #"{"a":1}"#)

		let outcome = assembler.finishBlock(messageID: "m1", blockIndex: 0)

		XCTAssertEqual(assembledInput(outcome)?["a"] as? Int, 1)
		if case let .assembled(result) = outcome {
			XCTAssertNil(result.toolName)
			XCTAssertNil(result.toolUseID)
		} else {
			XCTFail("should assemble even without a start")
		}
	}

	func testDuplicateStartResetsBuffer() {
		var assembler = ClaudePartialToolInputAssembler()
		assembler.beginBlock(messageID: "m1", blockIndex: 0, toolUseID: "t0", toolName: "Bash")
		_ = assembler.appendPartialJSON(messageID: "m1", blockIndex: 0, fragment: #"{"stale":true,"#)
		assembler.beginBlock(messageID: "m1", blockIndex: 0, toolUseID: "t0b", toolName: "Bash2")
		_ = assembler.appendPartialJSON(messageID: "m1", blockIndex: 0, fragment: #"{"fresh":true}"#)

		let outcome = assembler.finishBlock(messageID: "m1", blockIndex: 0)

		XCTAssertEqual(assembledInput(outcome)?["fresh"] as? Bool, true)
		XCTAssertNil(assembledInput(outcome)?["stale"])
		if case let .assembled(result) = outcome {
			XCTAssertEqual(result.toolName, "Bash2")
		}
	}

	func testDuplicateStopIsNoneSecondTime() {
		var assembler = ClaudePartialToolInputAssembler()
		assembler.beginBlock(messageID: "m1", blockIndex: 0, toolUseID: "t0", toolName: "Bash")
		_ = assembler.appendPartialJSON(messageID: "m1", blockIndex: 0, fragment: #"{"x":1}"#)

		_ = assembler.finishBlock(messageID: "m1", blockIndex: 0)
		let second = assembler.finishBlock(messageID: "m1", blockIndex: 0)

		guard case .none = second else {
			return XCTFail("second finish of the same block should be .none")
		}
	}

	// MARK: - Malformed completion

	func testMalformedCompletionYieldsMalformedWithRawBuffer() {
		var assembler = ClaudePartialToolInputAssembler()
		assembler.beginBlock(messageID: "m1", blockIndex: 0, toolUseID: "t0", toolName: "Bash")
		_ = assembler.appendPartialJSON(messageID: "m1", blockIndex: 0, fragment: #"{"command":"#)
		_ = assembler.appendPartialJSON(messageID: "m1", blockIndex: 0, fragment: "not-json")

		let outcome = assembler.finishBlock(messageID: "m1", blockIndex: 0)

		guard case let .malformed(_, blockIndex, _, _, rawBuffer) = outcome else {
			return XCTFail("malformed JSON should yield .malformed")
		}
		XCTAssertEqual(blockIndex, 0)
		XCTAssertEqual(rawBuffer, #"{"command":not-json"#)
		XCTAssertEqual(assembler.activeBlockCount, 0, "malformed block is cleaned up")
	}

	func testNonObjectJSONCompletionIsMalformed() {
		var assembler = ClaudePartialToolInputAssembler()
		assembler.beginBlock(messageID: "m1", blockIndex: 0, toolUseID: "t0", toolName: "Bash")
		_ = assembler.appendPartialJSON(messageID: "m1", blockIndex: 0, fragment: "[1,2,3]")

		guard case .malformed = assembler.finishBlock(messageID: "m1", blockIndex: 0) else {
			return XCTFail("a JSON array is not valid tool input")
		}
	}

	func testEmptyBufferFinishesAsEmptyInput() {
		var assembler = ClaudePartialToolInputAssembler()
		assembler.beginBlock(messageID: "m1", blockIndex: 0, toolUseID: "t0", toolName: "Bash")

		let outcome = assembler.finishBlock(messageID: "m1", blockIndex: 0)

		XCTAssertEqual(assembledInput(outcome)?.isEmpty, true)
	}

	// MARK: - Size limits

	func testSizeLimitYieldsMalformedAndClearsBlock() {
		var assembler = ClaudePartialToolInputAssembler(maxBufferBytes: 8)
		assembler.beginBlock(messageID: "m1", blockIndex: 0, toolUseID: "t0", toolName: "Bash")

		let outcome = assembler.appendPartialJSON(
			messageID: "m1", blockIndex: 0, fragment: #"{"command":"aaaaaaaaaaaaaaaa"}"#)

		guard case .malformed = outcome else {
			return XCTFail("exceeding the buffer limit should yield .malformed")
		}
		XCTAssertEqual(assembler.activeBlockCount, 0, "overflowed block is cleaned up")
	}

	// MARK: - Reset semantics

	func testResetMessageClearsOnlyThatMessagesBlocks() {
		var assembler = ClaudePartialToolInputAssembler()
		assembler.beginBlock(messageID: "m1", blockIndex: 0, toolUseID: "t0", toolName: "Bash")
		assembler.beginBlock(messageID: "m2", blockIndex: 0, toolUseID: "t1", toolName: "Read")

		assembler.resetMessage(messageID: "m1")

		XCTAssertEqual(assembler.activeBlockCount, 1)
		guard case .none = assembler.finishBlock(messageID: "m1", blockIndex: 0) else {
			return XCTFail("m1's block should be gone")
		}
		XCTAssertNotNil(assembledInput(assembler.finishBlock(messageID: "m2", blockIndex: 0)))
	}

	func testResetAllClearsEveryBlock() {
		var assembler = ClaudePartialToolInputAssembler()
		assembler.beginBlock(messageID: "m1", blockIndex: 0, toolUseID: "t0", toolName: "Bash")
		assembler.beginBlock(messageID: "m2", blockIndex: 1, toolUseID: "t1", toolName: "Read")

		assembler.resetAll()

		XCTAssertEqual(assembler.activeBlockCount, 0)
	}
}
