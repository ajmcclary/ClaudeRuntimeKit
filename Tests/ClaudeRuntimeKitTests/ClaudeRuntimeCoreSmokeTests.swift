import XCTest
@testable import ClaudeRuntimeKit

final class ClaudeRuntimeCoreSmokeTests: XCTestCase {
	func testModuleExposesPublicJSONValue() {
		XCTAssertEqual(ClaudeJSONValue.from("x"), .string("x"))
	}
}
