# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project Overview

Osaurus is a native macOS AI edge runtime for Apple Silicon. It runs local (MLX) and cloud models, exposes tools via MCP, and provides OpenAI/Anthropic/Ollama-compatible API endpoints. Built with SwiftUI + Swift 6.0, targeting macOS 15.5+.

## Build & Run

**Requirements:** macOS 15.5+, Apple Silicon (M1+), Xcode 16.4+

```bash
# Build CLI
make cli

# Build full app (includes CLI embedded in .app bundle)
make app

# Install CLI symlink to /usr/local/bin/osaurus
make install-cli

# Build + start server (default port 1337)
make serve                    # or: make serve PORT=8080 EXPOSE=1

# Clean build artifacts
make clean
```

Or open `osaurus.xcworkspace` in Xcode, select the `osaurus` scheme, and Run.

**Xcode project:** `App/osaurus.xcodeproj` — schemes: `osaurus` (app), `osaurus-cli` (CLI)

## Testing

```bash
# Run OsaurusCore tests from Xcode
xcodebuild test -project App/osaurus.xcodeproj -scheme OsaurusCore -derivedDataPath build/DerivedData -quiet

# Run a single test class
xcodebuild test -project App/osaurus.xcodeproj -scheme OsaurusCore -derivedDataPath build/DerivedData -only-testing:OsaurusCoreTests/ChatEngineTests -quiet

# OpenClaw coverage gate
make openclaw-coverage-gate
```

Tests live in `Packages/OsaurusCore/Tests/` (43+ test files) and `Packages/OsaurusCLI/Tests/`.

## Architecture

### Package Layout

```
App/osaurus/              → SwiftUI app entry point (thin shell, delegates to OsaurusCore)
Packages/
  OsaurusCore/            → Main framework (all app logic)
  OsaurusCLI/             → CLI executable (osaurus-cli) + OsaurusCLICore library
  OsaurusRepository/      → Shared data models between app and CLI
```

### OsaurusCore Internal Structure

| Directory       | Role |
|----------------|------|
| `Managers/`    | Stateful singletons managing lifecycle — `ChatWindowManager`, `ModelManager`, `AgentManager`, `OpenClawManager`, `PluginManager`, `ScheduleManager`, `WatcherManager`, etc. |
| `Services/`    | Core business logic — `ModelRuntime`, `MLXService`, `RemoteProviderService`, `ChatEngine`, `MCPServerManager`, `MCPProviderManager`, `OpenClawGatewayConnection`, `WhisperKitService`, `VADService` |
| `Models/`      | Data types — `Agent`, `ChatSessionData`, `ChatTurn`, `ContentBlock`, `OpenAIAPI`, `AnthropicAPI`, `OpenResponsesAPI`, OpenClaw models |
| `Views/`       | SwiftUI views — `ChatView`, `WorkView`, `ConfigurationView`, `AgentsView`, `SchedulesView`, `PluginsView`, `ServerView` |
| `Work/`        | Autonomous execution — `WorkBatchTool`, `WorkFolderTools`, `WorkFileOperation` |
| `Networking/`  | HTTP server (SwiftNIO) — `OsaurusServer`, `HTTPHandler`, `Router` |
| `Tools/`       | Plugin system and tool registry |
| `Storage/`     | Keychain + file persistence |
| `Controllers/` | Business logic controllers bridging managers and services |

### Key Patterns

- **MVVM + Combine** for reactive UI updates
- **Swift async/await** throughout (no completion handlers)
- **Singleton managers** accessed via `.shared` (e.g., `ChatWindowManager.shared`, `ModelManager.shared`)
- **SwiftNIO** for the HTTP server, async streams for WebSocket connections
- **Multi-window architecture** — each chat window has independent state via `ChatWindowState`

### API Compatibility Layer

The HTTP server (`Networking/`) exposes endpoints compatible with multiple formats:
- `/v1/chat/completions` — OpenAI format
- `/messages` — Anthropic format
- `/v1/responses` — Open Responses format
- `/mcp/*` — Model Context Protocol
- `/api/*` — Management endpoints

DTOs in `Models/OpenAIAPI.swift`, `Models/AnthropicAPI.swift`, `Models/OpenResponsesAPI.swift`.

### Tool Calling

- OpenAI-compatible DTOs in `Models/OpenAIAPI.swift` (`Tool`, `ToolFunction`, `ToolCall`, `DeltaToolCall`)
- Prompt templating handled internally by MLX `ChatSession` — Osaurus does not assemble prompts manually
- Relies on MLX `ToolCallProcessor` and event streaming from `MLXLMCommon.generate`
- Streaming tool calls emitted as OpenAI-style deltas in `Networking/AsyncHTTPHandler.swift`

### OpenClaw Integration

Active development area. Gateway connection via WebSocket (`OpenClawGatewayConnection`), with event processing (`OpenClawEventProcessor`), session management (`OpenClawSessionManager`), and launch agent support (`OpenClawLaunchAgent`). External dependency: `OpenClawKit` package at `../../../openclaw/apps/shared/OpenClawKit`.

## Key Dependencies

- **mlx-swift / mlx-swift-lm** — Local ML inference on Apple Silicon
- **swift-nio** — HTTP server foundation
- **swift-sdk** (MCP) — Model Context Protocol support
- **WhisperKit** — Local speech-to-text
- **Sparkle** — Auto-updates
- **IkigaJSON** — JSON parsing
- **OpenClawKit** — External gateway integration (local path dependency)

## Branching & Commits

- Branch from `main`: `feat/...`, `fix/...`, `docs/...`
- Prefer Conventional Commits
- `docs/FEATURES.md` is the **source of truth** for the feature inventory — update it when adding/modifying features
