# Snap

An IDL compiler for Roblox that generates typed, buffer-based networking code from `.blink` schemas.

## What is Snap?

Snap is a fork of [Blink](https://github.com/1Axen/Blink) (MIT licensed, attributed to 1Axen). It compiles `.blink` IDL schemas into:

- Typed client/server Luau modules using Roblox RemoteEvent/UnreliableRemoteEvent
- TypeScript declaration files (`.d.ts`)
- A Roblox Studio plugin for in-editor compilation

### Differences from upstream Blink

Snap adds the following runtime properties (all in `src/Templates` + `src/Generator`):

- Transactional sends (Serialize restores cursor + references on failure)
- ExportRead/ExportWrite state recovery
- PROTOCOL_VERSION=2 + SCHEMA_ID handshake on the reliable channel (client+server must be regenerated together—WIRE BREAKING vs upstream Blink)
- Single-combined-branch integer/representability guards
- String/buffer length + map count + array shape checks
- Corrected f16 codec
- CFrame<position,rotation> order
- Compile-time rejection of >256 ids/enums

## Quick Start

### Install Toolchain

Snap uses [rokit](https://github.com/rojo-rbx/rokit) to manage tooling. See `rokit.toml` for pinned versions:

```toml
lune = "filiptibell/lune@0.10.4"
rojo = "rojo-rbx/rojo@7.6.0"
stylua = "JohnnyMorganz/stylua@2.3.0"
run-in-roblox = "rojo-rbx/run-in-roblox@0.3.0"
larvae = "larvae-luau/larvae@0.9.0"
```

### Compile a Schema

From the repo root:

```bash
lune run src/CLI/init <file.blink> -- --yes
```

This generates client/server Luau modules, `.d.ts` declarations, and studio plugin assets.

## Schema Example

Minimal valid `.blink` schema (see `test/Sources/Indexers.blink` for more examples):

```blink
option ClientOutput = "Client.luau"
option ServerOutput = "Server.luau"

struct Point {
    X: f32,
    Y: f32,
    Z: f32,
}

event Ping {
    From: Client,
    Type: Reliable,
    Call: SingleAsync,
    Data: Point,
}
```

## Generated Runtime Guarantees

- Transactional reliability: cursor and references restored on serialize failure
- Protocol handshake: PROTOCOL_VERSION=2 + SCHEMA_ID on reliable channel
- Type safety: single-combined-branch integer/representability guards
- Length checks: string/buffer length, map count, array shape validation
- Codec correctness: f16 codec, CFrame<position,rotation> ordering
- Schema bounds: compile-time rejection of >256 ids/enums

## Toolchain

| Tool | Version | Source |
|------|---------|--------|
| lune | 0.10.4 | filiptibell/lune |
| rojo | 7.6.0 | rojo-rbx/rojo |
| stylua | 2.3.0 | JohnnyMorganz/stylua |
| run-in-roblox | 0.3.0 | rojo-rbx/run-in-roblox |
| larvae | 0.9.0 | larvae-luau/larvae *(replaces darklua)* |

## Testing & Benchmarks

Run tests (91 checks, from `test/`):

```bash
cd test
lune run Regression
```

Run benchmarks:
```bash
lune run benchmark/compile_bench
```

See `benchmark/Benchmarks.md` for results.

Build native binaries + pesde bundle + studio plugin:

```bash
lune run build
```

Lint (34 lints, selene-compatible names) and require/syntax gate:

```bash
larvae lint
larvae check
```

## Project Layout

```
src/
├── CLI/          # Command-line interface
├── Generator/    # Schema compiler and code generation
├── Modules/      # Shared runtime utilities
└── Templates/    # Code templates for client/server
test/             # Test fixtures and regression suite
benchmark/        # Performance benchmarks
plugin/           # Studio plugin source
docs/             # Documentation
Network/          # Network protocol fixtures
```

## License

MIT License. Derived from upstream [Blink](https://github.com/1Axen/Blink) by 1Axen.
