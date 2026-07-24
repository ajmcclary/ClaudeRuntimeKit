import XCTest
@testable import ClaudeRuntimeKit

final class ClaudeJSONValueTests: XCTestCase {
	func testFromConvertsNestedProviderObjectWithoutExposingAny() {
		let value = ClaudeJSONValue.from(["a": 1, "b": ["x": true], "c": [1, "s"]] as [String: Any])
		XCTAssertEqual(
			value,
			.object([
				"a": .number(1),
				"b": .object(["x": .bool(true)]),
				"c": .array([.number(1), .string("s")]),
			])
		)
	}

	func testFromMapsNilAndUnknownToNull() {
		XCTAssertEqual(ClaudeJSONValue.from(nil), .null)
	}
}
