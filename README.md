
Claude event envelopes and diagnostics retain immutable JSON bytes and provide
fresh Foundation views for legacy callers. Their identity, raw evidence,
redaction, unknown fields, and exact JSON integers are preserved; snapshots,
normalized events, diagnostic accumulators, and assembler state have checked
Sendable conformances. The package remains dependency-free with no process,
storage, or UI imports and keeps its macOS/iOS platform declarations.
