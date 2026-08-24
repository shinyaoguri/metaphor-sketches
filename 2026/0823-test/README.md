# 0823-test

A metaphor sketch generated with:

```bash
metaphor new 0823-test --template 2d
```

## Run

```bash
metaphor watch              # live-reload window, kept open across rebuilds
                            # (recommended while iterating; --no-viewer to skip the window)
swift run                   # plain SwiftPM run, no metaphor-cli needed
```

The sketch entry point is `Sources/Sketch0823Test/App.swift`.

## Editor

This project ships editor configuration for VS Code, and works in Xcode too
(same SwiftPM package — open it when you need Metal frame capture or the shader
profiler).

- `.vscode/tasks.json` — run `metaphor watch` (default build task, `⇧⌘B`),
  `metaphor run`, or `swift build` from the command palette. Swift compile
  errors land in the Problems panel.
- `.vscode/extensions.json` — recommends the Swift extension
  (`swiftlang.swift-vscode`), which provides completion, hover, and go-to-definition.

## AI-assisted iteration

This project ships ready for AI-assisted development. `.mcp.json` is included, so
Claude Code / Cursor / VS Code auto-connect to the `metaphor` MCP server and can
observe the running sketch (`snapshot`), check builds (`build_status`), and read the
API (`api_reference`). Start with `AGENTS.md`, and keep the creative target in
`PROJECT_BRIEF.md`.

`.mcp.json` launches the `metaphor` CLI found on your `PATH` — check that
`which metaphor` resolves (otherwise the MCP connection fails silently).

## Feedback

Found a bug or something confusing — in the library, the CLI, or the docs? Please
report it casually, however small:
[metaphor issues](https://github.com/shinyaoguri/metaphor/issues) ·
[metaphor-cli issues](https://github.com/shinyaoguri/metaphor-cli/issues)
