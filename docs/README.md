# Internal docs

Notes for whoever works on this next — very often a coding agent starting from
an empty context. The goal is that you can answer "where does X live and why is
it like that" without reading the source, and know which file to open when you
do need to.

User-facing documentation is the [root README](../README.md). This directory is
the other audience.

| Document | What it answers |
|---|---|
| [architecture.md](architecture.md) | Why there are two apps, what they share, how a click becomes an RPC call |
| [rpc.md](rpc.md) | The Transmission protocol as this project uses it, and every quirk that has bitten us |
| [config.md](config.md) | Every `config.json` key, who reads it, what breaks if you rename one |
| [linux.md](linux.md) | The PySide6 app, file by file |
| [macos.md](macos.md) | The Swift app, file by file (features are catalogued in [`macos/FEATURE_MAP.md`](../macos/FEATURE_MAP.md)) |
| [testing.md](testing.md) | Both suites, what they cover, and the parity contract between them |

## The short version

Two independent client apps for one remote Transmission server. The Linux one
is PySide6 in [`linux/flinger/`](../linux/flinger); the macOS one is Swift/SwiftUI in
[`macos/`](../macos). They share a config file format and a protocol, not code.
Neither can break the other, because neither imports the other.

## Working rules

- **Don't make one build depend on the other.** `macos/` may not require
  changes under `linux/flinger/`, `bin/`, `packaging/`, `scripts/` or `linux/tests/`, and
  vice versa. See [architecture.md](architecture.md) for why this is a rule and
  not a preference.
- **Ported logic changes twice.** `linux/flinger/core/` and
  `macos/Sources/TorrentFlinger/Core/` are deliberate duplicates. A rule change
  in formatting, path mapping or TV detection lands in both, with matching
  tests. [testing.md](testing.md) lists the pairs.
- **Keep the feature map current.** [`macos/FEATURE_MAP.md`](../macos/FEATURE_MAP.md)
  is the human-readable list of what the macOS app does. A stale feature map is
  worse than no feature map.
- **Both apps are agent-guided.** [`macos/CLAUDE.md`](../macos/CLAUDE.md) holds
  the macOS build's hard-won gotchas (Local Network permission, the zsh `log`
  builtin, `pkill` matching). Read it before touching that build.
