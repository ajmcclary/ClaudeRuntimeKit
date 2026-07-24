import XCTest
@testable import ClaudeRuntimeKit

/// Item 3: golden behaviour keys for the two certified runtimes.
///
/// Every hashed input is EVIDENCE-BACKED, none is an unexplained constant:
///   * `cliVersion` and `observedCapabilities` come from the interrupt canary's
///     `system/init` frames (spike report §6.4);
///   * `helpFlagSet` is parsed from the committed raw `--help` fixtures under
///     `Scripts/claude-compatibility/help/`, captured under the pinned contract
///     in `capture-claude-help.py` and described by
///     `claude-help-<version>.json` (parser `claude-help-long-options-ascii-v1`).
///
/// Goldens are computed EXTERNALLY with `shasum -a 256` over the canonical byte
/// strings pinned below, never by `ClaudeCanonicalDigest`.
///
/// NOTE, load-bearing: 2.1.215 and 2.1.216 emit BYTE-IDENTICAL `--help` output
/// and advertise identical capabilities, so their behaviour keys differ by
/// `cliVersion` alone. That is a real property of these runtimes, not a defect
/// here — and it means `behaviorKey` does NOT encode the 28-vs-32 tool-count
/// difference between them, because tool count is not one of its inputs.
final class ClaudeCertifiedBehaviorKeyTests: XCTestCase {

	/// Parsed from the committed raw fixtures; identical for both runtimes.
	private let certifiedHelpFlags: Set<String> = [
		"--add-dir",
		"--agent",
		"--agents",
		"--allow-dangerously-skip-permissions",
		"--allowed-tools",
		"--allowedTools",
		"--append-system-prompt",
		"--ax-screen-reader",
		"--background",
		"--bare",
		"--betas",
		"--bg",
		"--brief",
		"--chrome",
		"--continue",
		"--dangerously-skip-permissions",
		"--debug",
		"--debug-file",
		"--disable-slash-commands",
		"--disallowed-tools",
		"--disallowedTools",
		"--effort",
		"--exclude-dynamic-system-prompt-sections",
		"--fallback-model",
		"--file",
		"--fork-session",
		"--forward-subagent-text",
		"--from-pr",
		"--help",
		"--ide",
		"--include-hook-events",
		"--include-partial-messages",
		"--input-format",
		"--json-schema",
		"--max-budget-usd",
		"--mcp-config",
		"--model",
		"--name",
		"--no-chrome",
		"--no-session-persistence",
		"--output-format",
		"--permission-mode",
		"--plugin-dir",
		"--plugin-url",
		"--print",
		"--prompt-suggestions",
		"--remote-control",
		"--remote-control-session-name-prefix",
		"--replay-user-messages",
		"--resume",
		"--safe-mode",
		"--session-id",
		"--setting-sources",
		"--settings",
		"--strict-mcp-config",
		"--system-prompt",
		"--tmux",
		"--tools",
		"--verbose",
		"--version",
		"--worktree"
	]

	/// From `system/init.capabilities` on both runtimes.
	private let certifiedCapabilities: Set<String> = [
		"interrupt_receipt_v1", "msg_lifecycle_v1"
	]

	private let goldenBehaviorKey215 =
		"1821be7887667afc393067fd688379213dffbcd30d3d3c5daffdf292880f2b74"
	private let goldenBehaviorKey216 =
		"5d95f5e4b243521ac7bf4c654529984622b36cbabc3c3a83e9c29676eb217796"

	private let expectedCanonicalBytes215 = """
		{"cliVersion":"2.1.215","domain":"claude.behavior.v1","encodingVersion":"1","helpFlagSet":["--ad\
		d-dir","--agent","--agents","--allow-dangerously-skip-permissions","--allowed-tools","--allowedT\
		ools","--append-system-prompt","--ax-screen-reader","--background","--bare","--betas","--bg","--\
		brief","--chrome","--continue","--dangerously-skip-permissions","--debug","--debug-file","--disa\
		ble-slash-commands","--disallowed-tools","--disallowedTools","--effort","--exclude-dynamic-syste\
		m-prompt-sections","--fallback-model","--file","--fork-session","--forward-subagent-text","--fro\
		m-pr","--help","--ide","--include-hook-events","--include-partial-messages","--input-format","--\
		json-schema","--max-budget-usd","--mcp-config","--model","--name","--no-chrome","--no-session-pe\
		rsistence","--output-format","--permission-mode","--plugin-dir","--plugin-url","--print","--prom\
		pt-suggestions","--remote-control","--remote-control-session-name-prefix","--replay-user-message\
		s","--resume","--safe-mode","--session-id","--setting-sources","--settings","--strict-mcp-config\
		","--system-prompt","--tmux","--tools","--verbose","--version","--worktree"],"observedCapabiliti\
		es":["interrupt_receipt_v1","msg_lifecycle_v1"]}
		"""

	private let expectedCanonicalBytes216 = """
		{"cliVersion":"2.1.216","domain":"claude.behavior.v1","encodingVersion":"1","helpFlagSet":["--ad\
		d-dir","--agent","--agents","--allow-dangerously-skip-permissions","--allowed-tools","--allowedT\
		ools","--append-system-prompt","--ax-screen-reader","--background","--bare","--betas","--bg","--\
		brief","--chrome","--continue","--dangerously-skip-permissions","--debug","--debug-file","--disa\
		ble-slash-commands","--disallowed-tools","--disallowedTools","--effort","--exclude-dynamic-syste\
		m-prompt-sections","--fallback-model","--file","--fork-session","--forward-subagent-text","--fro\
		m-pr","--help","--ide","--include-hook-events","--include-partial-messages","--input-format","--\
		json-schema","--max-budget-usd","--mcp-config","--model","--name","--no-chrome","--no-session-pe\
		rsistence","--output-format","--permission-mode","--plugin-dir","--plugin-url","--print","--prom\
		pt-suggestions","--remote-control","--remote-control-session-name-prefix","--replay-user-message\
		s","--resume","--safe-mode","--session-id","--setting-sources","--settings","--strict-mcp-config\
		","--system-prompt","--tmux","--tools","--verbose","--version","--worktree"],"observedCapabiliti\
		es":["interrupt_receipt_v1","msg_lifecycle_v1"]}
		"""

	private func behaviorInput(_ version: String) -> ClaudeBehaviorKeyInput {
		ClaudeBehaviorKeyInput(
			cliVersion: ClaudeCliVersion.parse(version)!,
			helpFlagSet: certifiedHelpFlags,
			observedCapabilities: certifiedCapabilities
		)
	}

	func testCapturedHelpFlagSetHasTheExpectedShape() {
		XCTAssertEqual(certifiedHelpFlags.count, 61,
					   "captured long-option set changed; re-run the capture and re-golden")
		// Both bypass spellings exist in the CLI surface. §9.1.15 depends on this.
		XCTAssertTrue(certifiedHelpFlags.contains("--allow-dangerously-skip-permissions"))
		XCTAssertTrue(certifiedHelpFlags.contains("--dangerously-skip-permissions"))
	}

	func testBehaviorKeyCanonicalBytesMatchTheRecordedContract() {
		XCTAssertEqual(String(decoding: behaviorInput("2.1.215").canonicalBytes, as: UTF8.self),
					   expectedCanonicalBytes215)
		XCTAssertEqual(String(decoding: behaviorInput("2.1.216").canonicalBytes, as: UTF8.self),
					   expectedCanonicalBytes216)
	}

	func testBehaviorKeysMatchExternallyComputedGoldens() {
		XCTAssertEqual(ClaudeBehaviorKey(input: behaviorInput("2.1.215")).digest.value,
					   goldenBehaviorKey215)
		XCTAssertEqual(ClaudeBehaviorKey(input: behaviorInput("2.1.216")).digest.value,
					   goldenBehaviorKey216)
	}

	/// The two families must be DISTINCT even though only `cliVersion` separates
	/// them. If this ever passes by accident, the manifest would collapse two
	/// certified runtimes into one family.
	func testTheTwoCertifiedBehaviorKeysAreDistinct() {
		XCTAssertNotEqual(goldenBehaviorKey215, goldenBehaviorKey216)
		XCTAssertNotEqual(ClaudeBehaviorKey(input: behaviorInput("2.1.215")).digest.value,
						  ClaudeBehaviorKey(input: behaviorInput("2.1.216")).digest.value)
	}

	/// Mutation check: a single help flag must move the key. Without this, the
	/// goldens above could pass against an implementation that ignored
	/// `helpFlagSet` entirely — which is precisely the failure that would let a
	/// behaviourally different runtime share a family.
	func testRemovingOneHelpFlagMovesTheBehaviorKey() {
		var mutated = certifiedHelpFlags
		mutated.remove("--strict-mcp-config")
		let key = ClaudeBehaviorKey(input: ClaudeBehaviorKeyInput(
			cliVersion: ClaudeCliVersion.parse("2.1.215")!,
			helpFlagSet: mutated,
			observedCapabilities: certifiedCapabilities
		)).digest.value
		XCTAssertNotEqual(key, goldenBehaviorKey215,
						  "dropping a help flag did not move the behaviour key")
	}

	func testAddingOneHelpFlagMovesTheBehaviorKey() {
		var mutated = certifiedHelpFlags
		mutated.insert("--not-a-real-flag")
		let key = ClaudeBehaviorKey(input: ClaudeBehaviorKeyInput(
			cliVersion: ClaudeCliVersion.parse("2.1.215")!,
			helpFlagSet: mutated,
			observedCapabilities: certifiedCapabilities
		)).digest.value
		XCTAssertNotEqual(key, goldenBehaviorKey215,
						  "adding a help flag did not move the behaviour key")
	}
}
