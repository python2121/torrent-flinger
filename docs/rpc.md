# The Transmission RPC layer

Two implementations of the same client:

- `flinger/core/transmission.py` — `urllib`, blocking, called from a Qt thread pool
- `macos/Sources/TorrentFlinger/Core/TransmissionClient.swift` — `URLSession`,
  `async`/`await`, an `actor` because the session id is mutable state shared
  across concurrent calls

Spec: <https://github.com/transmission/transmission/blob/main/docs/rpc-spec.md>

**We target the pre-4.1 protocol**, which is what Transmission 3.x, 4.x and the
NAS reimplementations all speak. Don't adopt a 4.1-only field without a
fallback; the servers this app exists for are usually old.

## Request shape

Every call is a POST of `{"method": …, "arguments": {…}}` to
`{protocol}://{host}:{port}{rpc_path}`, and every response is
`{"result": "success"|"<error>", "arguments": {…}}`. A `result` other than
`"success"` is an error even though the HTTP status was 200 — check it.

## The five things that will bite you

1. **The 409 CSRF handshake.** The first request of a session comes back
   `409 Conflict` with an `X-Transmission-Session-Id` header. Store it, repeat
   the request once. Retry exactly once: a second 409 is a real failure, not a
   handshake, and retrying forever is an infinite loop against a misconfigured
   proxy. Both clients implement this, and both suites test it.

2. **`ids: null` means every torrent; `ids: []` must be a no-op.** The
   difference is pausing nothing versus pausing everything. Both clients
   special-case the empty list before it reaches the wire, and both suites
   assert it. Don't "simplify" this away.

3. **Mixed key casing in one object.** `torrent-get` returns camelCase fields,
   except `peer-limit`, which is kebab-case in the middle of them. Request
   arguments are worse: `download-dir`, `delete-local-data`, `files-wanted`,
   `priority-high` are kebab-case while `seedRatioLimit` and `uploadLimit` are
   camelCase. Copy the exact spelling from the spec; don't infer it.

4. **`fileStats[].wanted` is 0/1, not a boolean** — on some servers. Decode it
   permissively. Both mock servers reproduce this on purpose.

5. **Fields you asked for may not come back.** Different server versions omit
   different things. Every field decodes to a documented default; nothing throws
   on a missing key. This is why the Swift models hand-write `init(from:)`
   instead of relying on synthesized `Codable`.

## Methods used

| Method | Used for | Notes |
|---|---|---|
| `torrent-get` | the list poll and the details view | Without `ids` → all torrents with `TORRENT_FIELDS`; with `ids` → one torrent with `DETAIL_FIELDS`. Same method, two very different payload sizes — that's why the field lists are split. |
| `torrent-add` | magnets and `.torrent` files | Magnet → `filename`; file → base64 in `metainfo`. Success returns **either** `torrent-added` **or** `torrent-duplicate`; a duplicate is not an error, and the UI says so rather than claiming a new add. |
| `torrent-start` / `torrent-stop` | resume / pause | `ids` semantics above. |
| `torrent-remove` | remove | `delete-local-data` decides whether the payload goes too. |
| `torrent-set` | per-file wanted/priority, per-torrent limits, seed ratio | Free-form passthrough; the Swift side uses `JSONValue` for exactly this. |
| `torrent-set-location` | move data | `move: true` relocates, `false` just re-points. |
| `torrent-verify`, `torrent-reannounce` | recheck, re-announce | |
| `queue-move-{top,up,down,bottom}` | queue order | Four methods, not one with a parameter. |
| `session-get` | server defaults, global limits | Called with `["download-dir"]` on the hot path — asking for everything on every poll is wasteful. |
| `session-set` | global limits, turtle mode, seed ratio | Applied live from the Options window. |
| `session-stats` | aggregate speeds, session/cumulative totals | The macOS build also polls this alone, fast, for the menu bar. |
| `free-space` | the footer and the add dialog | Decoration: never fail a poll over it. |
| `port-test` | the Options window's connectivity check | |

## Field lists

`TORRENT_FIELDS` (~24 fields) is what the list needs: identity, status,
progress, rates, peers, error, dates, queue position, magnet link, download dir.

`DETAIL_FIELDS` adds ~25 more for one torrent at a time: hash, comment, creator,
piece geometry, privacy, per-torrent limits, seed-ratio mode, and the four big
arrays — `files`, `fileStats`, `peers`, `trackerStats`.

Keep the two lists in step across builds. They're duplicated in
`transmission.py` and `TransmissionClient.swift`, in the same order, so a diff
between them is readable.

## Error mapping

| Condition | Linux | macOS |
|---|---|---|
| 401 / 403 | `AuthFailed` | `TransmissionError.authFailed` |
| Transport failure | `ConnectionFailed` | `.connectionFailed` |
| `result != "success"` | `TransmissionError` | `.requestFailed` |
| Torrent id absent | `TransmissionError` | `.notFound(id)` |
| macOS Local Network block (`NSURLErrorNotConnectedToInternet`, -1009) | n/a | `.localNetworkBlocked` — mapped specially so the UI can say something actionable instead of "the Internet connection appears to be offline". See [`macos/CLAUDE.md`](../macos/CLAUDE.md). |

## TLS

Self-signed certificates on a NAS are the normal case, so both clients can opt
out of verification (`verify_tls` / `verifyTLS` in config). Linux builds an
unverified `ssl` context; macOS uses a `URLSessionDelegate` that accepts the
server trust. It's opt-in per config and applies only to `https://` URLs.
