# Testing

Two suites, one for each build, plus a parity contract between them.

```bash
# Linux / Python — from linux/
cd linux
PYTHONPATH=. .venv/bin/python -m unittest discover tests
.venv/bin/ruff check flinger tests

# macOS / Swift
cd macos && ./test.sh
cd macos && ./test.sh client/      # filter by test-name substring
```

## The Python suite (`linux/tests/`)

`unittest`, driven against a mock Transmission server that runs in-process.

- **`test_core.py`** — the RPC client, config, formatting, path mapping, TV
  detection. `MockRPC` is a real `HTTPServer` on a thread, reproducing the 409
  handshake, Basic auth, and the protocol's casing quirks on purpose:
  `fileStats[].wanted` as 0/1, `peer-limit` kebab-case among camelCase.
- **`test_ui.py`** — popup grouping, filtering, expansion, the dialogs, and a
  full-app integration pass, run offscreen (`QT_QPA_PLATFORM=offscreen`).

**The config-redirection trap.** Both files depend on
`TORRENT_FLINGER_CONFIG_DIR` being set to a throwaway directory *before* any
import that can save. It's set at the top of `test_core.py`, and `test_ui.py`
imports it for that reason as much as for `MockRPC`. `XDG_CONFIG_HOME` does not
work for this: `config_dir()` rightly ignores it on macOS, and that once let the
suite overwrite a real user's config. If you add a test module that touches
`Config`, import from `tests.test_core` rather than minting your own directory —
two modules each setting the variable leaves the loser writing where nothing
reads.

## The Swift suite (`macos/Sources/TorrentFlinger/SelfTest/`)

**There is no `swift test` here, and no testing package.** Command Line Tools
ship neither XCTest nor swift-testing, and pulling in a package dependency for a
suite this size wasn't worth it. So the harness is hand-rolled:
`TestHarness.swift` is a `TestCase` collector, a `TestEntry` registry and a
runner that prints a report and returns an exit code. `SelfTest.runIfRequested`
is dispatched from `App.main` *before* the single-instance lock and before
`NSApplication`, so running tests never disturbs an installed copy.

Everything under `SelfTest/` is `#if DEBUG`, so the release build carries none
of it. Wrap anything you add the same way.

Coverage as of this writing: 90 cases / 420 checks over formatting, path
mapping, TV detection, config load/save, torrent state classification, list
grouping and search, selection arithmetic, custom-directory rules, the Files
tab's directory tree, the menu bar's speed smoothing, and the RPC client against
`MockRPC` (a `URLProtocol` reproducing the same quirks as the Python mock) plus
`FailingTransport` for URLSession-error mapping.

It deliberately does **not** cover SwiftUI rendering or the AppKit panel. Those
are verified by running the app — see `DebugWindow` in [macos.md](macos.md).

## The parity contract

`linux/tests/test_core.py` is the reference for shared behaviour. When you change a
formatting rule, a path-mapping rule, a TV-detection pattern or the tray-icon
precedence in one build, the other build's test for it should still describe the
same behaviour. If it doesn't, the two have drifted.

Pairs that are asserted on both sides:

| Rule | Python | Swift |
|---|---|---|
| Sizes and speeds (SI, 1000-based) | `test_core.py` | `FormatTests` |
| ETA formatting, `-1` → empty | `test_core.py` | `FormatTests` |
| `map_remote_path` component matching | `test_core.py` | `FormatTests` |
| TV detection patterns | `test_core.py` | `ConfigTests` / `UILogicTests` |
| Tray-icon precedence and the 3 s "added" duration | `test_core.py` | `UILogicTests` |
| The Files tab's directory tree: ids, ordering, aggregates, tri-state | `test_core.py` | `FileTreeTests` |
| `ids: []` is a no-op, `ids: nil` is everything | `test_core.py` | `ClientTests` |
| The 409 handshake | `MockRPC` | `MockRPC` |

## When to run

During development, after finishing a change, and always before pushing.

`macos/.githooks/pre-push` enforces the last one — it runs `./test.sh` and, when
a `.venv` exists, the Python suite too, so a push can't break the other target.
**It is not active until you opt in**, since Git doesn't share hooks:

```bash
git config core.hooksPath macos/.githooks
```

Without that, nothing runs your tests for you. There's no CI in this repo.

## Writing a new Swift test

```swift
TestEntry("area/what-it-pins") { t in
    t.equal(actual, expected, "why this matters")
    t.expect(condition, "message shown on failure")
}
```

Register the array in `SelfTest.entries`. Two habits worth keeping:

- **Prove the test can fail.** Disable the fix, watch the assertion fail for the
  reason it claims, restore. Several of the speed-averaging tests were written
  this way and one of them turned out to be vacuous — it passed against the
  broken implementation until it was rewritten.
- **Inject the clock.** Anything time-dependent takes a timestamp parameter, so
  a minute of a download runs instantly and deterministically. `SpeedAverager`
  is the model to copy.
