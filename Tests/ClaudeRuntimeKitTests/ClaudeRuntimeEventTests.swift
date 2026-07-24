import XCTest
@testable import ClaudeRuntimeKit

final class ClaudeRuntimeEventTests: XCTestCase {
	func testToolUseIdentityAndSourceAreDistinct() {
		let streamed = ClaudeRuntimeEvent.toolUse(.init(
			messageID: "m1", blockIndex: 0, toolID: "toolu_1", name: "Bash",
			input: "{\"command\":\"ls\"}", source: .streamed, extra: [:]))
		let complete = ClaudeRuntimeEvent.toolUse(.init(
			messageID: "m1", blockIndex: 0, toolID: "toolu_1", name: "Bash",
			input: "{\"command\":\"ls\"}", source: .complete, extra: [:]))
		XCTAssertNotEqual(streamed, complete)
	}

	func testResultCarriesSessionAndText() {
		let event = ClaudeRuntimeEvent.result(.init(
			sessionID: "sid", subtype: "success", isError: false, text: "done", extra: [:]))
		guard case .result(let r) = event else { return XCTFail() }
		XCTAssertEqual(r.sessionID, "sid")
		XCTAssertEqual(r.text, "done")
	}
}
