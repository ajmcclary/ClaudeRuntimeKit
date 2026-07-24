// swift-tools-version: 6.0
import PackageDescription

// ClaudeRuntimeKit — Claude-specific, UI-free runtime foundations.
//
// Promoted verbatim out of RepoPrompt's internal RepoPromptCore package
// (its ClaudeRuntimeCore target) as the seventh extraction of the
// migrate.md package map and the third provider-runtime promotion
// (staged-plan step 5). RepoPromptCore's ClaudeRuntimeCore target is now
// an @_exported re-export shim over this package (the AgentRuntimeKit /
// PromptAssemblyKit / ApplyEditsKit / CodexRuntimeKit /
// CodexAppServerKit promotion precedent).
//
// Scope — deterministic Claude runtime values and pure policy:
//   * CLI version, runtime identity, compatibility keys, the strict
//     compatibility manifest with its fail-closed decoder, and the
//     certified launch-profile / behavior-key value types;
//   * admission coordination, enforcement staging, behavioral validation,
//     and the diagnostic value models;
//   * Claude event envelopes, ClaudeJSONValue, the normalized runtime
//     event vocabulary, partial tool-input assembly, and structural
//     credential redaction;
//   * lifecycle stamps, events, parity, drift, and reconciliation;
//   * usage identity, cache-aware breakdown, and the usage ledger.
//
// Deliberately OUT of scope — RepoPrompt keeps all of it:
// Claude process spawning and ownership, launch-profile CONSTRUCTION,
// executable discovery, environment composition and sanitization, retry,
// cancellation, and termination; authentication acquisition, subscription
// and account policy, credential storage, and every user interaction;
// the compatibility-manifest RESOURCE and its loader (this package
// decodes `Data` and never touches Bundle/FileManager), manifest
// generation, and fixture/evidence curation; observation-history storage,
// persistence, workspace authority, MCP server policy, session and
// transcript ownership, permission policy, projection into app chat
// models, and all UI. This package is intentionally Claude-specific — it
// is not a multi-provider abstraction, and provider-neutral agent
// vocabulary lives in AgentRuntimeKit alongside it.
//
// Zero package dependencies (Foundation plus the CryptoKit system
// framework for the SHA-256 canonical digests behind the compatibility
// keys). Swift 5 language mode keeps the moved code byte-behaviorally
// identical (AgentRuntimeKit / PromptAssemblyKit / ApplyEditsKit /
// CodexRuntimeKit / RepoPromptCore promoted-target precedent).
let package = Package(
    name: "ClaudeRuntimeKit",
    platforms: [
        .macOS(.v14),
        .iOS(.v17)
    ],
    products: [
        .library(name: "ClaudeRuntimeKit", targets: ["ClaudeRuntimeKit"])
    ],
    targets: [
        .target(
            name: "ClaudeRuntimeKit",
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
        .testTarget(
            name: "ClaudeRuntimeKitTests",
            dependencies: ["ClaudeRuntimeKit"],
            swiftSettings: [.swiftLanguageMode(.v5)]
        )
    ]
)
