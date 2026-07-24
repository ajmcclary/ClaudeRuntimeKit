import XCTest
@testable import ClaudeRuntimeKit

// Item 5 of the compatibility-admission plan: the strict, fail-closed manifest
// value types and decoder that live in the pure core.
//
// The decoder is the runtime's first line of defence AFTER item 3's build-time
// resource gate: a manifest that reaches the app but carries an invalid hash,
// an unbounded enum, an inverted version range, or a malformed known-bad match
// must be REJECTED with a specific reason, never silently coerced. These tests
// pin every one of those refusals.
//
// The decoder takes `Data` and never touches `Bundle`/`FileManager`: the app-side
// loader owns the resource layout, the core owns the decoding rules.

final class ClaudeCompatibilityManifestTests: XCTestCase {

	// A faithful copy of the two-family committed manifest, minus insignificant
	// whitespace. The real resource is exercised app-side through the loader; this
	// inline copy lets the pure decoder be tested with zero filesystem coupling.
	private static let validManifestJSON = """
	{
	  "schemaVersion": 1,
	  "manifestVersion": "2026-07-21.1",
	  "families": [
	    {
	      "behaviorKey": "1821be7887667afc393067fd688379213dffbcd30d3d3c5daffdf292880f2b74",
	      "cliVersionRange": { "min": "2.1.215", "max": "2.1.215" },
	      "certifiedIdentities": [
	        {
	          "sha256": "90608b5c5ab504e96e77365cea6203d046e291d59b2bb42cf28dcb2ccdf9dd58",
	          "launchProfileKey": "e831b109495ed27b600b61725fcc7fea03ce4d3dafe4654b9653035897feb0dc",
	          "signingClass": "appleDeveloperID"
	        }
	      ],
	      "classification": "supported",
	      "capabilities": {
	        "models": [],
	        "effortLevels": [],
	        "structuredOutput": { "state": "uncertified", "evidence": "" },
	        "resume": { "state": "uncertified", "evidence": "" },
	        "interrupt": {
	          "state": "certified",
	          "method": "in-flight-canary",
	          "abortSignals": ["assistant.aborted==true", "result.terminal_reason==aborted_streaming"],
	          "evidence": "canary:inflight-interrupt-2026-07-21/v2.1.215"
	        },
	        "permissionModeRoundTrip": true
	      },
	      "limitations": ["resume uncertified under the exact profile"],
	      "evidence": ["interrupt certified via in-flight-canary"]
	    },
	    {
	      "behaviorKey": "5d95f5e4b243521ac7bf4c654529984622b36cbabc3c3a83e9c29676eb217796",
	      "cliVersionRange": { "min": "2.1.216", "max": "2.1.216" },
	      "certifiedIdentities": [
	        {
	          "sha256": "d01b49210d72ecbe277a2665d104bacccddf2d22185be99446d2929e0edfc48d",
	          "launchProfileKey": "e831b109495ed27b600b61725fcc7fea03ce4d3dafe4654b9653035897feb0dc",
	          "signingClass": "appleDeveloperID"
	        }
	      ],
	      "classification": "supported",
	      "capabilities": {
	        "models": [],
	        "effortLevels": [],
	        "structuredOutput": { "state": "uncertified", "evidence": "" },
	        "resume": { "state": "uncertified", "evidence": "" },
	        "interrupt": {
	          "state": "certified",
	          "method": "in-flight-canary",
	          "abortSignals": ["assistant.aborted==true", "result.terminal_reason==aborted_streaming"],
	          "evidence": "canary:inflight-interrupt-2026-07-21/v2.1.216"
	        },
	        "permissionModeRoundTrip": true
	      },
	      "limitations": ["resume uncertified under the exact profile"],
	      "evidence": ["interrupt certified via in-flight-canary"]
	    }
	  ],
	  "knownBadRules": []
	}
	"""

	private func decode(_ json: String) throws -> ClaudeCompatibilityManifest {
		try ClaudeCompatibilityManifest.decode(from: Data(json.utf8))
	}

	// MARK: - Faithful decode

	func testDecodesCommittedManifestFaithfully() throws {
		let manifest = try decode(Self.validManifestJSON)

		XCTAssertEqual(manifest.schemaVersion, 1)
		XCTAssertEqual(manifest.manifestVersion, "2026-07-21.1")
		XCTAssertEqual(manifest.families.count, 2)
		XCTAssertTrue(manifest.knownBadRules.isEmpty)

		let v215 = manifest.families[0]
		XCTAssertEqual(v215.behaviorKey.digest.value,
			"1821be7887667afc393067fd688379213dffbcd30d3d3c5daffdf292880f2b74")
		XCTAssertEqual(v215.classification, .supported)
		XCTAssertEqual(v215.cliVersionRange.min, ClaudeCliVersion.parse("2.1.215"))
		XCTAssertEqual(v215.cliVersionRange.max, ClaudeCliVersion.parse("2.1.215"))
		XCTAssertEqual(v215.certifiedIdentities.count, 1)
		XCTAssertEqual(v215.certifiedIdentities[0].sha256.value,
			"90608b5c5ab504e96e77365cea6203d046e291d59b2bb42cf28dcb2ccdf9dd58")
		XCTAssertEqual(v215.certifiedIdentities[0].launchProfileKey.digest.value,
			"e831b109495ed27b600b61725fcc7fea03ce4d3dafe4654b9653035897feb0dc")
		XCTAssertEqual(v215.certifiedIdentities[0].signingClass, .appleDeveloperID)

		// The load-bearing capability shape: interrupt certified, resume and
		// structured output UNCERTIFIED. §4.8's per-capability override rests on this.
		XCTAssertEqual(v215.capabilities.interrupt.state, .certified)
		XCTAssertEqual(v215.capabilities.interrupt.method, .inFlightCanary)
		XCTAssertEqual(v215.capabilities.interrupt.abortSignals,
			[.assistantAborted, .resultTerminalReasonAbortedStreaming])
		XCTAssertEqual(v215.capabilities.resume.state, .uncertified)
		XCTAssertEqual(v215.capabilities.structuredOutput.state, .uncertified)
		XCTAssertTrue(v215.capabilities.permissionModeRoundTrip)
		XCTAssertTrue(v215.capabilities.models.isEmpty)
		XCTAssertTrue(v215.capabilities.effortLevels.isEmpty)

		XCTAssertEqual(manifest.families[1].cliVersionRange.min, ClaudeCliVersion.parse("2.1.216"))
	}

	func testRejectsEmptyFamilies() {
		// A PACKAGED resource with no families is schema-invalid (families minItems 1)
		// and must fail closed. Only the APPLICATION constructs a conservative
		// fallback (`.empty`); the decoder never produces one.
		let emptyFamilies = """
		{ "schemaVersion": 1, "manifestVersion": "2026-07-21.1", "families": [], "knownBadRules": [] }
		"""
		XCTAssertThrowsError(try decode(emptyFamilies)) { error in
			guard case ClaudeManifestDecodingError.emptyArray(let field) = error else {
				return XCTFail("expected .emptyArray(families), got \(error)")
			}
			XCTAssertEqual(field, "families")
		}
	}

	func testRejectsEmptyCertifiedIdentities() {
		let bad = Self.validManifestJSON.replacingOccurrences(
			of: """
			"certifiedIdentities": [
			        {
			          "sha256": "90608b5c5ab504e96e77365cea6203d046e291d59b2bb42cf28dcb2ccdf9dd58",
			          "launchProfileKey": "e831b109495ed27b600b61725fcc7fea03ce4d3dafe4654b9653035897feb0dc",
			          "signingClass": "appleDeveloperID"
			        }
			      ]
			""",
			with: "\"certifiedIdentities\": []")
		XCTAssertThrowsError(try decode(bad)) { error in
			guard case ClaudeManifestDecodingError.emptyArray(let field) = error else {
				return XCTFail("expected .emptyArray(certifiedIdentities), got \(error)")
			}
			XCTAssertEqual(field, "certifiedIdentities")
		}
	}

	func testRejectsUnknownTopLevelProperty() {
		let bad = Self.validManifestJSON.replacingOccurrences(
			of: "\"schemaVersion\": 1,",
			with: "\"schemaVersion\": 1, \"surprise\": true,")
		XCTAssertThrowsError(try decode(bad)) { error in
			guard case ClaudeManifestDecodingError.unexpectedProperty(_, let property) = error else {
				return XCTFail("expected .unexpectedProperty, got \(error)")
			}
			XCTAssertEqual(property, "surprise")
		}
	}

	func testRejectsUnknownFamilyProperty() {
		let bad = Self.validManifestJSON.replacingOccurrences(
			of: "\"classification\": \"supported\",",
			with: "\"classification\": \"supported\", \"vibes\": \"good\",")
		XCTAssertThrowsError(try decode(bad)) { error in
			guard case ClaudeManifestDecodingError.unexpectedProperty(_, let property) = error else {
				return XCTFail("expected .unexpectedProperty, got \(error)")
			}
			XCTAssertEqual(property, "vibes")
		}
	}

	func testRejectsWrongSchemaVersion() {
		let bad = Self.validManifestJSON.replacingOccurrences(
			of: "\"schemaVersion\": 1", with: "\"schemaVersion\": 2")
		XCTAssertThrowsError(try decode(bad)) { error in
			guard case ClaudeManifestDecodingError.unexpectedSchemaVersion(2) = error else {
				return XCTFail("expected .unexpectedSchemaVersion(2), got \(error)")
			}
		}
	}

	func testRejectsMalformedManifestVersion() {
		let bad = Self.validManifestJSON.replacingOccurrences(
			of: "\"manifestVersion\": \"2026-07-21.1\"",
			with: "\"manifestVersion\": \"2026-07-21\"")
		XCTAssertThrowsError(try decode(bad)) { error in
			guard case ClaudeManifestDecodingError.malformedManifestVersion("2026-07-21") = error else {
				return XCTFail("expected .malformedManifestVersion, got \(error)")
			}
		}
	}

	func testRejectsPrereleaseInVersionRange() {
		// The schema's exactVersion is a bare triple; a prerelease suffix is invalid
		// even though ClaudeCliVersion.parse would accept it.
		let bad = Self.validManifestJSON.replacingOccurrences(
			of: "{ \"min\": \"2.1.215\", \"max\": \"2.1.215\" }",
			with: "{ \"min\": \"2.1.215-beta.1\", \"max\": \"2.1.215-beta.1\" }")
		XCTAssertThrowsError(try decode(bad)) { error in
			guard case ClaudeManifestDecodingError.malformedVersion(let raw) = error else {
				return XCTFail("expected .malformedVersion, got \(error)")
			}
			XCTAssertEqual(raw, "2.1.215-beta.1")
		}
	}

	func testRejectsSingleAbortSignal() {
		let bad = Self.validManifestJSON.replacingOccurrences(
			of: "[\"assistant.aborted==true\", \"result.terminal_reason==aborted_streaming\"]",
			with: "[\"assistant.aborted==true\"]")
		XCTAssertThrowsError(try decode(bad)) { error in
			guard case ClaudeManifestDecodingError.invalidAbortSignalCardinality(1) = error else {
				return XCTFail("expected .invalidAbortSignalCardinality(1), got \(error)")
			}
		}
	}

	func testRejectsDuplicateAbortSignals() {
		let bad = Self.validManifestJSON.replacingOccurrences(
			of: "[\"assistant.aborted==true\", \"result.terminal_reason==aborted_streaming\"]",
			with: "[\"assistant.aborted==true\", \"assistant.aborted==true\"]")
		XCTAssertThrowsError(try decode(bad)) { error in
			guard case ClaudeManifestDecodingError.invalidAbortSignalCardinality(1) = error else {
				return XCTFail("expected .invalidAbortSignalCardinality(1) after dedup, got \(error)")
			}
		}
	}

	func testRejectsThreeSignalsWithDuplicate() {
		// maxItems:2 + uniqueItems: a 3-element array carrying the two valid signals
		// plus a duplicate must fail, even though the deduplicated set has count 2.
		// The RAW array length must also equal 2.
		let bad = Self.validManifestJSON.replacingOccurrences(
			of: "[\"assistant.aborted==true\", \"result.terminal_reason==aborted_streaming\"]",
			with: "[\"assistant.aborted==true\", \"result.terminal_reason==aborted_streaming\", \"assistant.aborted==true\"]")
		XCTAssertThrowsError(try decode(bad)) { error in
			guard case ClaudeManifestDecodingError.invalidAbortSignalCardinality(3) = error else {
				return XCTFail("expected .invalidAbortSignalCardinality(3), got \(error)")
			}
		}
	}

	func testRejectsFractionalSchemaVersion() {
		// NSNumber.intValue would truncate 1.5 → 1 and pass the const check. The
		// decoder must reject a non-integer number.
		let bad = Self.validManifestJSON.replacingOccurrences(
			of: "\"schemaVersion\": 1", with: "\"schemaVersion\": 1.5")
		XCTAssertThrowsError(try decode(bad)) { error in
			guard case ClaudeManifestDecodingError.wrongType(let field) = error else {
				return XCTFail("expected .wrongType(schemaVersion), got \(error)")
			}
			XCTAssertEqual(field, "schemaVersion")
		}
	}

	func testRejectsOversizedSchemaVersionNumber() {
		// 1e300 is a finite, integral double beyond 2^53 — it must be rejected as a
		// non-exact integer rather than truncated. (1e309 would overflow JSON parsing
		// itself; 1e300 exercises the decoder's own range guard.)
		let bad = Self.validManifestJSON.replacingOccurrences(
			of: "\"schemaVersion\": 1", with: "\"schemaVersion\": 1e300")
		XCTAssertThrowsError(try decode(bad)) { error in
			guard case ClaudeManifestDecodingError.wrongType = error else {
				return XCTFail("expected .wrongType for an oversized number, got \(error)")
			}
		}
	}

	func testRejectsFloatSchemaVersionForCrossGateParity() {
		// CROSS-GATE PARITY: the authoritative complete-inline Python validator types
		// `integer` as `isinstance(v, int) and not bool`, and Python decodes `1.0` as a
		// float, so the build gate REJECTS `1.0`. The runtime decoder must reject it
		// too, or a shape the build gate rejects would pass at runtime.
		let bad = Self.validManifestJSON.replacingOccurrences(
			of: "\"schemaVersion\": 1", with: "\"schemaVersion\": 1.0")
		XCTAssertThrowsError(try decode(bad)) { error in
			guard case ClaudeManifestDecodingError.wrongType(let field) = error else {
				return XCTFail("expected .wrongType(schemaVersion) for a float, got \(error)")
			}
			XCTAssertEqual(field, "schemaVersion")
		}
	}

	func testRejectsDuplicateCertifiedIdentityAcrossFamilies() {
		// #2: the same (sha256, launchProfileKey) in two families would let family
		// order decide admission. Global uniqueness is required at decode.
		let secondFamily = """
		,
		{
		  "behaviorKey": "5d95f5e4b243521ac7bf4c654529984622b36cbabc3c3a83e9c29676eb217796",
		  "cliVersionRange": { "min": "2.1.216", "max": "2.1.216" },
		  "certifiedIdentities": [
		    {
		      "sha256": "90608b5c5ab504e96e77365cea6203d046e291d59b2bb42cf28dcb2ccdf9dd58",
		      "launchProfileKey": "e831b109495ed27b600b61725fcc7fea03ce4d3dafe4654b9653035897feb0dc",
		      "signingClass": "appleDeveloperID"
		    }
		  ],
		  "classification": "external-only",
		  "capabilities": {
		    "models": [], "effortLevels": [],
		    "structuredOutput": { "state": "uncertified", "evidence": "" },
		    "resume": { "state": "uncertified", "evidence": "" },
		    "interrupt": {
		      "state": "certified", "method": "in-flight-canary",
		      "abortSignals": ["assistant.aborted==true", "result.terminal_reason==aborted_streaming"],
		      "evidence": "canary:x"
		    },
		    "permissionModeRoundTrip": true
		  },
		  "limitations": ["dupe"],
		  "evidence": ["dupe"]
		}
		"""
		// Insert the duplicate family right before the closing `]` of families.
		let bad = Self.validManifestJSON.replacingOccurrences(
			of: "\n  ],\n  \"knownBadRules\": []",
			with: "\(secondFamily)\n  ],\n  \"knownBadRules\": []")
		XCTAssertThrowsError(try decode(bad)) { error in
			guard case ClaudeManifestDecodingError.duplicateCertifiedIdentity = error else {
				return XCTFail("expected .duplicateCertifiedIdentity, got \(error)")
			}
		}
	}

	func testRejectsEmptyLimitationString() {
		let bad = Self.validManifestJSON.replacingOccurrences(
			of: "\"limitations\": [\"resume uncertified under the exact profile\"]",
			with: "\"limitations\": [\"\"]")
		XCTAssertThrowsError(try decode(bad)) { error in
			guard case ClaudeManifestDecodingError.emptyString(let field) = error else {
				return XCTFail("expected .emptyString(limitations), got \(error)")
			}
			XCTAssertEqual(field, "limitations")
		}
	}

	func testRejectsEmptyInterruptEvidence() {
		let bad = Self.validManifestJSON.replacingOccurrences(
			of: "\"evidence\": \"canary:inflight-interrupt-2026-07-21/v2.1.215\"",
			with: "\"evidence\": \"\"")
		XCTAssertThrowsError(try decode(bad)) { error in
			guard case ClaudeManifestDecodingError.emptyString(let field) = error else {
				return XCTFail("expected .emptyString(interrupt.evidence), got \(error)")
			}
			XCTAssertEqual(field, "evidence")
		}
	}

	// MARK: - Fail-closed: hashes

	func testRejectsInvalidBehaviorKeyHash() {
		let bad = Self.validManifestJSON.replacingOccurrences(
			of: "1821be7887667afc393067fd688379213dffbcd30d3d3c5daffdf292880f2b74",
			with: "NOTAHEX")
		XCTAssertThrowsError(try decode(bad)) { error in
			guard case ClaudeManifestDecodingError.invalidHash(let field) = error else {
				return XCTFail("expected .invalidHash, got \(error)")
			}
			XCTAssertEqual(field, "behaviorKey")
		}
	}

	func testRejectsUppercaseHash() {
		// ClaudeSHA256 rejects uppercase as a producer-invariant violation; the
		// decoder must surface that, not lowercase-and-accept.
		let bad = Self.validManifestJSON.replacingOccurrences(
			of: "90608b5c5ab504e96e77365cea6203d046e291d59b2bb42cf28dcb2ccdf9dd58",
			with: "90608B5C5AB504E96E77365CEA6203D046E291D59B2BB42CF28DCB2CCDF9DD58")
		XCTAssertThrowsError(try decode(bad)) { error in
			guard case ClaudeManifestDecodingError.invalidHash = error else {
				return XCTFail("expected .invalidHash, got \(error)")
			}
		}
	}

	// MARK: - Fail-closed: enums

	func testRejectsUnknownClassification() {
		let bad = Self.validManifestJSON.replacingOccurrences(
			of: "\"classification\": \"supported\"",
			with: "\"classification\": \"blessed\"")
		XCTAssertThrowsError(try decode(bad)) { error in
			guard case ClaudeManifestDecodingError.invalidEnum(let field, let value) = error else {
				return XCTFail("expected .invalidEnum, got \(error)")
			}
			XCTAssertEqual(field, "classification")
			XCTAssertEqual(value, "blessed")
		}
	}

	func testRejectsUnknownSigningClass() {
		let bad = Self.validManifestJSON.replacingOccurrences(
			of: "\"signingClass\": \"appleDeveloperID\"",
			with: "\"signingClass\": \"selfSigned\"")
		XCTAssertThrowsError(try decode(bad)) { error in
			guard case ClaudeManifestDecodingError.invalidEnum(let field, _) = error else {
				return XCTFail("expected .invalidEnum, got \(error)")
			}
			XCTAssertEqual(field, "signingClass")
		}
	}

	func testRejectsUnknownCapabilityState() {
		let bad = Self.validManifestJSON.replacingOccurrences(
			of: "\"resume\": { \"state\": \"uncertified\", \"evidence\": \"\" }",
			with: "\"resume\": { \"state\": \"probably\", \"evidence\": \"\" }")
		XCTAssertThrowsError(try decode(bad)) { error in
			guard case ClaudeManifestDecodingError.invalidEnum(let field, _) = error else {
				return XCTFail("expected .invalidEnum, got \(error)")
			}
			XCTAssertEqual(field, "state")
		}
	}

	func testRejectsUnknownAbortSignal() {
		let bad = Self.validManifestJSON.replacingOccurrences(
			of: "\"result.terminal_reason==aborted_streaming\"",
			with: "\"result.aborted==true\"")
		XCTAssertThrowsError(try decode(bad)) { error in
			guard case ClaudeManifestDecodingError.invalidEnum(let field, _) = error else {
				return XCTFail("expected .invalidEnum, got \(error)")
			}
			XCTAssertEqual(field, "abortSignals")
		}
	}

	func testRejectsUnknownInterruptMethod() {
		let bad = Self.validManifestJSON.replacingOccurrences(
			of: "\"method\": \"in-flight-canary\"",
			with: "\"method\": \"idle-ack\"")
		XCTAssertThrowsError(try decode(bad)) { error in
			guard case ClaudeManifestDecodingError.invalidEnum(let field, _) = error else {
				return XCTFail("expected .invalidEnum, got \(error)")
			}
			XCTAssertEqual(field, "method")
		}
	}

	// MARK: - Fail-closed: version ranges

	func testRejectsMalformedVersion() {
		let bad = Self.validManifestJSON.replacingOccurrences(
			of: "{ \"min\": \"2.1.215\", \"max\": \"2.1.215\" }",
			with: "{ \"min\": \"2.1\", \"max\": \"2.1.215\" }")
		XCTAssertThrowsError(try decode(bad)) { error in
			guard case ClaudeManifestDecodingError.malformedVersion(let raw) = error else {
				return XCTFail("expected .malformedVersion, got \(error)")
			}
			XCTAssertEqual(raw, "2.1")
		}
	}

	func testRejectsInvertedVersionRange() {
		let bad = Self.validManifestJSON.replacingOccurrences(
			of: "{ \"min\": \"2.1.216\", \"max\": \"2.1.216\" }",
			with: "{ \"min\": \"2.1.216\", \"max\": \"2.1.215\" }")
		XCTAssertThrowsError(try decode(bad)) { error in
			guard case ClaudeManifestDecodingError.invertedVersionRange = error else {
				return XCTFail("expected .invertedVersionRange, got \(error)")
			}
		}
	}

	// MARK: - Fail-closed: known-bad match axes

	func testRejectsKnownBadRuleWithZeroMatchAxes() {
		let bad = Self.validManifestJSON.replacingOccurrences(
			of: "\"knownBadRules\": []",
			with: "\"knownBadRules\": [ { \"match\": {}, \"reason\": \"x\" } ]")
		XCTAssertThrowsError(try decode(bad)) { error in
			guard case ClaudeManifestDecodingError.knownBadMatchAxisCount(let count) = error else {
				return XCTFail("expected .knownBadMatchAxisCount, got \(error)")
			}
			XCTAssertEqual(count, 0)
		}
	}

	func testRejectsKnownBadRuleWithMultipleMatchAxes() {
		let two = """
		{ "match": { \
		"sha256": "90608b5c5ab504e96e77365cea6203d046e291d59b2bb42cf28dcb2ccdf9dd58", \
		"behaviorKey": "1821be7887667afc393067fd688379213dffbcd30d3d3c5daffdf292880f2b74" \
		}, "reason": "x" }
		"""
		let bad = Self.validManifestJSON.replacingOccurrences(
			of: "\"knownBadRules\": []",
			with: "\"knownBadRules\": [ \(two) ]")
		XCTAssertThrowsError(try decode(bad)) { error in
			guard case ClaudeManifestDecodingError.knownBadMatchAxisCount(let count) = error else {
				return XCTFail("expected .knownBadMatchAxisCount, got \(error)")
			}
			XCTAssertEqual(count, 2)
		}
	}

	func testDecodesKnownBadRuleOnEachAxis() throws {
		let sha = "90608b5c5ab504e96e77365cea6203d046e291d59b2bb42cf28dcb2ccdf9dd58"
		let rules = """
		[ { "match": { "sha256": "\(sha)" }, "reason": "s" },
		  { "match": { "behaviorKey": "\(sha)" }, "reason": "b" },
		  { "match": { "certificationKey": "\(sha)" }, "reason": "c" } ]
		"""
		let good = Self.validManifestJSON.replacingOccurrences(
			of: "\"knownBadRules\": []", with: "\"knownBadRules\": \(rules)")
		let manifest = try decode(good)
		XCTAssertEqual(manifest.knownBadRules.count, 3)
		guard case .sha256 = manifest.knownBadRules[0].match else { return XCTFail("axis 0") }
		guard case .behaviorKey = manifest.knownBadRules[1].match else { return XCTFail("axis 1") }
		guard case .certificationKey = manifest.knownBadRules[2].match else { return XCTFail("axis 2") }
	}

	// MARK: - Fail-closed: structure

	func testRejectsMissingRequiredKey() {
		let bad = Self.validManifestJSON.replacingOccurrences(
			of: "\"classification\": \"supported\",", with: "")
		XCTAssertThrowsError(try decode(bad)) { error in
			guard case ClaudeManifestDecodingError.missingKey(let key) = error else {
				return XCTFail("expected .missingKey, got \(error)")
			}
			XCTAssertEqual(key, "classification")
		}
	}

	func testRejectsNonObjectRoot() {
		XCTAssertThrowsError(try decode("[]")) { error in
			guard case ClaudeManifestDecodingError.notAnObject = error else {
				return XCTFail("expected .notAnObject, got \(error)")
			}
		}
	}
}
