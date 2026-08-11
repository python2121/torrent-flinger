# Configuration

One JSON file, read and written by both apps, with identical key names. This is
the only intentional coupling between the two builds.

## Where it lives

| Platform | Path |
|---|---|
| Linux | `$XDG_CONFIG_HOME/torrent-flinger/config.json` (default `~/.config/…`) |
| macOS | `~/Library/Application Support/torrent-flinger/config.json` |
| Either | `$TORRENT_FLINGER_CONFIG_DIR/config.json` when that variable is set |

The override exists because `XDG_CONFIG_HOME` is (correctly) ignored on macOS,
which once let the test suite overwrite a real user's config. Tests and
sandboxes set `TORRENT_FLINGER_CONFIG_DIR`.

Saves are atomic-ish and `chmod 0600`, because the RPC password is in there in
plain text. That's a deliberate, documented trade: Transmission's RPC auth is
HTTP Basic, the app must replay it on every call, and a Keychain round trip per
poll buys little against an attacker who can already read your home directory.

## Keys

| Key | Type | Default | Meaning |
|---|---|---|---|
| `protocol` | string | `"http"` | `http` or `https` |
| `host` | string | `"localhost"` | Server hostname or IP |
| `port` | int | `9091` | RPC port |
| `rpc_path` | string | `"/transmission/rpc"` | RPC endpoint path |
| `web_path` | string | `"/transmission/web/"` | Where "Full web interface" opens |
| `username` | string | `""` | HTTP Basic user |
| `password` | string | `""` | HTTP Basic password (plain text, see above) |
| `verify_tls` | bool | `true` | Verify the certificate; off for self-signed NAS certs |
| `notify_on_add` | bool | `true` | Notify when a torrent is accepted |
| `notify_on_finish` | bool | `true` | Notify when one completes |
| `poll_interval_ms` | int | `3000` | Poll cadence **while the panel is open** (30 s is hard-coded while closed) |
| `start_paused` | bool | `false` | Add torrents paused |
| `show_add_dialog` | bool | `true` | Show the destination dialog on a new link; off means "use the defaults silently" |
| `custom_dirs` | array | `[]` | `[{"label": "TV", "dir": "/srv/tv", "tv": true}]` — destinations offered in the add dialog |
| `last_download_dir` | string | `""` | Remembered destination, pre-selected next time |
| `mount_remote` | string | `""` | Server-side prefix for path mapping; empty means "derive it" |
| `mount_local` | string | `""` | Where that prefix is mounted locally |
| `menubar_show_speeds` | bool | `true` | **macOS only.** Draw speeds next to the menu-bar icon. Ignored by the Linux app. |

### Naming notes

- **`protocol` is `scheme` in Swift.** `protocol` is a keyword, so the Swift
  property is `scheme` with a `CodingKey` mapping back. The JSON key is
  `protocol` and must stay that way.
- **Everything is `snake_case` on the wire**, mapped to `camelCase` in Swift by
  explicit `CodingKeys`.
- **`custom_dirs[].tv` is omitted when false** by both writers, so a round trip
  through either app doesn't churn the file.

## Compatibility rules

Both apps **ignore keys they don't know** and both fall back to defaults for
anything missing or malformed — a corrupt config yields a default config, never
a crash and never an empty file.

That means adding a key is safe, but:

1. **Give it a default that reads sensibly to the other build.** The other app
   will not write it and will not honour it; the file must still make sense.
2. **Never rename an existing key.** There's no migration layer, and the other
   build would silently fall back to its default.
3. **Platform-specific keys are fine** (`menubar_show_speeds` is the precedent),
   as long as rule 1 holds.

## Path mapping

"Reveal in Finder"/"Reveal in Dolphin" has to turn a server path
(`/srv/torrents/complete/thing`) into a local one
(`/Volumes/torrents/complete/thing`). `mount_remote` and `mount_local` are the
two ends of that translation.

When `mount_remote` is empty it's **derived**: the common root of the server's
default `download-dir` and every `custom_dirs[].dir`. So a server with
`/data/complete` and `/data/tv` resolves a prefix of `/data`, and both map
correctly through one local mount.

Matching is on **path components**, not string prefixes — otherwise
`/data/torrents2` would match a `/data/torrents` prefix and produce a path that
doesn't exist. `map_remote_path` / `Format.mapRemotePath` implement this, and
it's one of the rules tested identically on both sides.
