import Foundation

/// Assembles streamed `input_json_delta` tool input, keyed by message + block
/// index, and parses only at block stop (Program A / Slice 1; ClaudeRuntimeCore).
///
/// Fragments are concatenated exactly as received. At block stop the buffer is
/// parsed once: a JSON object becomes assembled tool input; anything else (or an
/// over-limit buffer) yields `.malformed` with the raw buffer preserved so the
/// caller can emit a non-fatal diagnostic and a compatibility best-effort result.
///
/// Reset points are explicit and owned by the translator:
/// - block stop -> `finishBlock` removes that one block;
/// - message stop -> `resetMessage` removes all blocks for that message;
/// - result / new message generation -> `resetAll`.
public struct ClaudePartialToolInputAssembler {
	public struct AssembledToolInput {
		public let messageID: String?
		public let blockIndex: Int
		public let toolUseID: String?
		public let toolName: String?
		public let input: [String: Any]
	}

	public enum Outcome {
		case none
		case assembled(AssembledToolInput)
		case malformed(
			messageID: String?,
			blockIndex: Int,
			toolUseID: String?,
			toolName: String?,
			rawBuffer: String
		)
	}

	private struct BlockKey: Hashable {
		let messageID: String?
		let index: Int
	}

	private struct BlockState {
		var toolUseID: String?
		var toolName: String?
		var buffer: String
	}

	public let maxBufferBytes: Int
	private var blocks: [BlockKey: BlockState] = [:]

	public init(maxBufferBytes: Int = 1_000_000) {
		self.maxBufferBytes = maxBufferBytes
	}

	public var activeBlockCount: Int { blocks.count }

	public mutating func beginBlock(
		messageID: String?,
		blockIndex: Int,
		toolUseID: String?,
		toolName: String?
	) {
		// A start (including a duplicate) begins a fresh buffer for the block.
		blocks[BlockKey(messageID: messageID, index: blockIndex)] = BlockState(
			toolUseID: toolUseID,
			toolName: toolName,
			buffer: ""
		)
	}

	public mutating func appendPartialJSON(
		messageID: String?,
		blockIndex: Int,
		fragment: String
	) -> Outcome {
		let key = BlockKey(messageID: messageID, index: blockIndex)
		// Tolerate a missing start by lazily creating the block (unknown tool).
		var state = blocks[key] ?? BlockState(toolUseID: nil, toolName: nil, buffer: "")
		let combined = state.buffer + fragment
		if combined.utf8.count > maxBufferBytes {
			blocks[key] = nil
			return .malformed(
				messageID: messageID,
				blockIndex: blockIndex,
				toolUseID: state.toolUseID,
				toolName: state.toolName,
				rawBuffer: combined
			)
		}
		state.buffer = combined
		blocks[key] = state
		return .none
	}

	public mutating func finishBlock(messageID: String?, blockIndex: Int) -> Outcome {
		let key = BlockKey(messageID: messageID, index: blockIndex)
		guard let state = blocks[key] else { return .none }
		blocks[key] = nil // reset at block stop

		if state.buffer.isEmpty {
			return .assembled(AssembledToolInput(
				messageID: messageID,
				blockIndex: blockIndex,
				toolUseID: state.toolUseID,
				toolName: state.toolName,
				input: [:]
			))
		}

		guard
			let data = state.buffer.data(using: .utf8),
			let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
		else {
			return .malformed(
				messageID: messageID,
				blockIndex: blockIndex,
				toolUseID: state.toolUseID,
				toolName: state.toolName,
				rawBuffer: state.buffer
			)
		}

		return .assembled(AssembledToolInput(
			messageID: messageID,
			blockIndex: blockIndex,
			toolUseID: state.toolUseID,
			toolName: state.toolName,
			input: object
		))
	}

	public mutating func resetMessage(messageID: String?) {
		blocks = blocks.filter { $0.key.messageID != messageID }
	}

	public mutating func resetAll() {
		blocks.removeAll()
	}
}
