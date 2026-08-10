#!/usr/bin/env bash
# Run the self-test suite. Takes an optional name filter:
#
#   ./test.sh                # everything
#   ./test.sh client/        # just the RPC client tests
#
# The suite is hand-rolled (Sources/TorrentFlinger/SelfTest) and compiled only
# into debug builds, so this deliberately does not use `swift test` — there's
# no XCTest bundle to run.
set -euo pipefail

cd "$(dirname "$0")"
exec swift run TorrentFlinger --self-test "$@"
