"""Core tests against a mock Transmission RPC server (409 handshake included).

Run (from linux/): .venv/bin/python -m unittest discover tests
"""
import base64
import json
import os
import tempfile
import threading
import unittest
from http.server import BaseHTTPRequestHandler, HTTPServer

# Before importing anything that can save: no test may touch the real config.
# On macOS config_dir() ignores XDG_CONFIG_HOME, so this override is the only
# redirection that holds on both platforms. Defined here, the module every
# other test file imports, so the whole suite shares one throwaway directory —
# two modules each minting their own would leave the loser writing to a path
# nothing reads.
CONFIG_DIR = tempfile.mkdtemp(prefix="flinger-config-")
os.environ["TORRENT_FLINGER_CONFIG_DIR"] = CONFIG_DIR

from flinger.core.config import Config
from flinger.core.formats import fmt_eta, fmt_size, fmt_speed, link_display_name
from flinger.core.transmission import AuthFailed, TransmissionClient

SESSION_ID = "test-session-id"


# One realistic torrent as the old (3.x/4.x-compatible) protocol serializes it.
# Note the spec gotchas encoded here on purpose: fileStats[].wanted is 0/1 (not
# a boolean) and "peer-limit" is kebab-case inside a camelCase object.
DETAIL_TORRENT = {
    "id": 1, "name": "test.iso", "status": 4, "percentDone": 0.5,
    "hashString": "abc123", "magnetLink": "magnet:?xt=urn:btih:abc123",
    "downloadDir": "/data", "comment": "", "queuePosition": 0,
    "peer-limit": 50, "seedRatioLimit": 2.0, "seedRatioMode": 0,
    "files": [{"name": "test.iso", "length": 100, "bytesCompleted": 50}],
    "fileStats": [{"bytesCompleted": 50, "wanted": 1, "priority": 0}],
    "peers": [{"address": "10.0.0.2", "clientName": "qBittorrent/4.6",
               "progress": 0.9, "rateToClient": 1000, "rateToPeer": 0,
               "flagStr": "DE", "isEncrypted": True, "port": 51413}],
    "trackerStats": [{"host": "tracker.example.org", "announce": "http://tracker.example.org/announce",
                      "lastAnnounceResult": "Success", "lastAnnounceSucceeded": True,
                      "seederCount": 12, "leecherCount": 3, "tier": 0,
                      "nextAnnounceTime": 0}],
}


class MockRPC(BaseHTTPRequestHandler):
    require_auth = False
    calls: list = []  # (method, arguments) log for assertions

    def log_message(self, *args):
        pass

    def do_POST(self):
        if self.require_auth and self.headers.get("Authorization") != (
                "Basic " + base64.b64encode(b"user:pass").decode()):
            self.send_response(401)
            self.end_headers()
            return
        if self.headers.get("X-Transmission-Session-Id") != SESSION_ID:
            self.send_response(409)
            self.send_header("X-Transmission-Session-Id", SESSION_ID)
            self.end_headers()
            return
        payload = json.loads(self.rfile.read(int(self.headers["Content-Length"])))
        method = payload["method"]
        args = payload.get("arguments", {})
        MockRPC.calls.append((method, args))
        if method == "torrent-get":
            result = {"torrents": [DETAIL_TORRENT]}
        elif method == "torrent-add":
            if args.get("filename", "").startswith("magnet:?xt=urn:btih:dup"):
                result = {"torrent-duplicate": {"id": 1, "name": "test.iso"}}
            else:
                assert "filename" in args or "metainfo" in args
                result = {"torrent-added": {"id": 2, "name": "new.iso"}}
        elif method == "session-get":
            result = {"version": "4.0.5", "rpc-version": 17,
                      "alt-speed-enabled": False, "download-dir": "/data",
                      "speed-limit-down": 1000, "speed-limit-down-enabled": False,
                      "speed-limit-up": 100, "speed-limit-up-enabled": True,
                      "alt-speed-down": 50, "alt-speed-up": 10,
                      "seedRatioLimit": 2.0, "seedRatioLimited": False}
        elif method == "session-stats":
            result = {"downloadSpeed": 1000, "uploadSpeed": 500,
                      "torrentCount": 1, "activeTorrentCount": 1,
                      "pausedTorrentCount": 0,
                      "current-stats": {"uploadedBytes": 10, "downloadedBytes": 20,
                                        "filesAdded": 1, "sessionCount": 1,
                                        "secondsActive": 60},
                      "cumulative-stats": {"uploadedBytes": 100, "downloadedBytes": 200,
                                           "filesAdded": 5, "sessionCount": 9,
                                           "secondsActive": 6000}}
        elif method == "free-space":
            assert "path" in args
            result = {"path": args["path"], "size-bytes": 123456789,
                      "total_size": 1000000000}
        elif method == "port-test":
            result = {"port-is-open": True}
        elif method in ("torrent-start", "torrent-stop", "torrent-remove",
                        "torrent-set", "torrent-set-location", "torrent-verify",
                        "torrent-reannounce", "session-set", "queue-move-top",
                        "queue-move-up", "queue-move-down", "queue-move-bottom"):
            result = {}
        else:
            raise AssertionError(f"mock got unexpected method {method}")
        body = json.dumps({"result": "success", "arguments": result}).encode()
        self.send_response(200)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)


class TestTransmissionClient(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.server = HTTPServer(("127.0.0.1", 0), MockRPC)
        cls.port = cls.server.server_address[1]
        threading.Thread(target=cls.server.serve_forever, daemon=True).start()

    @classmethod
    def tearDownClass(cls):
        cls.server.shutdown()

    def client(self, **kw):
        return TransmissionClient(f"http://127.0.0.1:{self.port}/transmission/rpc", **kw)

    def test_handshake_and_torrent_get(self):
        torrents = self.client().torrents()
        self.assertEqual(torrents[0]["name"], "test.iso")

    def test_add_magnet(self):
        status, info = self.client().add("magnet:?xt=urn:btih:abc&dn=new.iso")
        self.assertEqual(status, "added")
        self.assertEqual(info["name"], "new.iso")

    def test_add_duplicate(self):
        status, _ = self.client().add("magnet:?xt=urn:btih:dup")
        self.assertEqual(status, "duplicate")

    def test_add_torrent_file(self):
        import tempfile
        with tempfile.NamedTemporaryFile(suffix=".torrent", delete=False) as f:
            f.write(b"d8:announce3:urle")
        status, _ = self.client().add(f.name)
        self.assertEqual(status, "added")

    def test_auth_failure(self):
        MockRPC.require_auth = True
        try:
            with self.assertRaises(AuthFailed):
                self.client(username="user", password="wrong").torrents()
            self.client(username="user", password="pass").torrents()  # correct creds pass
        finally:
            MockRPC.require_auth = False

    def test_session(self):
        client = self.client()
        self.assertEqual(client.session_get(["version"])["version"], "4.0.5")
        self.assertEqual(client.session_stats()["downloadSpeed"], 1000)

    def last_call(self):
        return MockRPC.calls[-1]

    def test_details(self):
        details = self.client().torrent_details(1)
        self.assertEqual(details["hashString"], "abc123")
        self.assertEqual(details["fileStats"][0]["wanted"], 1)  # 0/1, not bool
        self.assertEqual(details["peer-limit"], 50)             # kebab oddball
        _method, args = self.last_call()
        self.assertEqual(args["ids"], [1])
        self.assertIn("trackerStats", args["fields"])

    def test_torrent_set_files(self):
        self.client().torrent_set([1], {"files-unwanted": [0], "priority-high": [2]})
        method, args = self.last_call()
        self.assertEqual(method, "torrent-set")
        self.assertEqual(args, {"ids": [1], "files-unwanted": [0], "priority-high": [2]})

    def test_set_location(self):
        self.client().set_location([1], "/data/tv", move=True)
        method, args = self.last_call()
        self.assertEqual(method, "torrent-set-location")
        self.assertEqual(args, {"ids": [1], "location": "/data/tv", "move": True})

    def test_verify_reannounce_queue(self):
        client = self.client()
        client.verify([1])
        self.assertEqual(self.last_call()[0], "torrent-verify")
        client.reannounce([1])
        self.assertEqual(self.last_call()[0], "torrent-reannounce")
        client.queue_move([1], "top")
        self.assertEqual(self.last_call(), ("queue-move-top", {"ids": [1]}))
        with self.assertRaises(ValueError):
            client.queue_move([1], "sideways")

    def test_start_stop_semantics(self):
        client = self.client()
        client.start()  # None → all torrents → ids omitted from the call
        method, args = self.last_call()
        self.assertEqual(method, "torrent-start")
        self.assertNotIn("ids", args)
        before = len(MockRPC.calls)
        client.start([])  # empty list → no-op, no RPC call at all
        self.assertEqual(len(MockRPC.calls), before)
        client.stop([1])
        self.assertEqual(self.last_call(), ("torrent-stop", {"ids": [1]}))

    def test_remove_wire_format(self):
        self.client().remove([1], delete_data=True)
        self.assertEqual(self.last_call(),
                         ("torrent-remove", {"ids": [1], "delete-local-data": True}))

    def test_free_space_and_port(self):
        client = self.client()
        self.assertEqual(client.free_space("/data"), 123456789)
        self.assertTrue(client.port_test())

    def test_session_set(self):
        self.client().session_set({"speed-limit-down": 500,
                                   "speed-limit-down-enabled": True})
        method, args = self.last_call()
        self.assertEqual(method, "session-set")
        self.assertEqual(args["speed-limit-down"], 500)

    def test_session_stats_cumulative(self):
        stats = self.client().session_stats()
        self.assertEqual(stats["cumulative-stats"]["sessionCount"], 9)


class TestFormats(unittest.TestCase):
    def test_sizes(self):
        self.assertEqual(fmt_size(500), "500 B")
        self.assertEqual(fmt_size(1500), "1.5 KB")
        self.assertEqual(fmt_size(2_500_000_000), "2.5 GB")
        self.assertEqual(fmt_speed(1_200_000), "1.2 MB/s")

    def test_eta(self):
        self.assertEqual(fmt_eta(-1), "")
        self.assertEqual(fmt_eta(45), "45s")
        self.assertEqual(fmt_eta(3900), "1h 5m")
        self.assertEqual(fmt_eta(90000), "1d 1h")

    def test_map_remote_path(self):
        from flinger.core.formats import map_remote_path
        self.assertEqual(map_remote_path("/data/torrents/tv", "/data/torrents",
                                         "/run/media/nas"), "/run/media/nas/tv")
        self.assertEqual(map_remote_path("/data/torrents", "/data/torrents",
                                         "/run/media/nas"), "/run/media/nas")
        self.assertEqual(map_remote_path("/data/torrents/", "/data/torrents",
                                         "/run/media/nas/"), "/run/media/nas")
        self.assertIsNone(map_remote_path("/other/place", "/data/torrents", "/mnt"))
        # prefix match must be on path components, not raw string prefixes
        self.assertIsNone(map_remote_path("/data/torrents2/x", "/data/torrents", "/mnt"))
        self.assertIsNone(map_remote_path("/data/x", "", "/mnt"))
        self.assertIsNone(map_remote_path("/data/x", "/data", ""))

    def test_common_remote_root(self):
        from flinger.core.formats import common_remote_root
        self.assertEqual(common_remote_root(["/data/complete", "/data/tv"]), "/data")
        self.assertEqual(common_remote_root(["/data/torrents"]), "/data/torrents")
        self.assertIsNone(common_remote_root(["/data/tv", "/mnt/other"]))  # only "/"
        self.assertIsNone(common_remote_root([]))
        self.assertIsNone(common_remote_root(["", "relative/path"]))

    def test_resolve_local_path(self):
        from flinger.core.formats import resolve_local_path
        # the user's scenario: movies in default /data/complete, tv in custom
        # /data/tv, share root /data mounted at /mnt/nas
        tree = {"/mnt/nas", "/mnt/nas/complete", "/mnt/nas/complete/MovieX",
                "/mnt/nas/tv", "/mnt/nas/tv/ShowY"}
        exists = tree.__contains__
        self.assertEqual(resolve_local_path("/data/complete/MovieX", "/data",
                                            "/mnt/nas", exists),
                         "/mnt/nas/complete/MovieX")
        self.assertEqual(resolve_local_path("/data/tv", "/data", "/mnt/nas", exists),
                         "/mnt/nas/tv")
        # wrong/missing prefix → suffix probing still finds the alignment
        self.assertEqual(resolve_local_path("/data/tv/ShowY", "/data/complete",
                                            "/mnt/nas", exists),
                         "/mnt/nas/tv/ShowY")
        self.assertEqual(resolve_local_path("/srv/deep/data/tv", "", "/mnt/nas", exists),
                         "/mnt/nas/tv")  # longest existing suffix wins
        # nothing exists locally → no reveal
        self.assertIsNone(resolve_local_path("/data/other", "/data", "/mnt/nas", exists))
        # mapped path must actually exist, never invented
        self.assertIsNone(resolve_local_path("/data/tv", "/data", "/mnt/gone",
                                             lambda p: False))

    def test_link_names(self):
        self.assertEqual(link_display_name("magnet:?xt=urn:btih:x&dn=My+File"), "My File")
        self.assertEqual(link_display_name("/tmp/some%20file.torrent"), "some file.torrent")


class TestTVDetect(unittest.TestCase):
    TV_NAMES = [
        # episode markers — the workhorse signal
        ("The.Bear.S03E05.1080p.WEB.h264-ETHEL", "episode"),
        ("shogun.s01e09.720p.hdtv.x264", "episode"),
        ("The Wire 3x07 Back Burners", "episode"),
        ("Severance.S2E1.2160p.ATVP.WEB-DL", "episode"),
        ("Unknown.Obscure.Show.S01E01.480p", "episode"),  # no list needed
        # air-date naming (daily shows)
        ("Last.Week.Tonight.2026.08.03.1080p.WEB", "air-date"),
        ("The.Daily.Show.2026-01-15.720p.HEVC", "air-date"),
        # season packs
        ("True.Detective.S04.2160p.WEB.COMPLETE", "season"),
        ("Andor.Season.2.1080p.DSNP.WEB-DL", "season"),
        ("Chernobyl.Complete.Series.1080p.BluRay", "season"),
        ("Band.of.Brothers.Mini-Series.720p", "season"),
        ("The.Sopranos.Seasons.1-6.DVDRip", "season"),
    ]
    NOT_TV_NAMES = [
        "Oppenheimer.2023.1080p.BluRay.x264-GROUP",
        "Fargo.1996.REMASTERED.1080p.BluRay",     # movie/show name collision
        "Watchmen.2009.Ultimate.Cut.2160p",
        "Friends.with.Benefits.2011.720p",        # contains a show title
        "1917.2019.2160p.HDR.REMUX",
        "2001.A.Space.Odyssey.1968.1080p",
        "Dune.Part.Two.2024.HDR.2160p",
        "Inception.1080p.BluRay.x264",
        "James.Bond.Complete.Collection.1080p",   # pack words alone don't count
        "Se7en.1995.720p",
        "Gladiator",
        # bare show names without markers are intentionally NOT detected —
        # marker-free packs are rare and title-matching wasn't worth its
        # false-positive risk (movie/show collisions)
        "Breaking Bad",
        "The Wire Complete 1080p",
    ]

    def test_tv_positives(self):
        from flinger.core.tvdetect import looks_like_tv
        for name, expected_reason in self.TV_NAMES:
            is_tv, reason = looks_like_tv(name)
            self.assertTrue(is_tv, f"missed TV: {name}")
            self.assertEqual(reason, expected_reason, name)

    def test_movie_negatives(self):
        from flinger.core.tvdetect import looks_like_tv
        for name in self.NOT_TV_NAMES:
            is_tv, reason = looks_like_tv(name)
            self.assertFalse(is_tv, f"false positive: {name} ({reason})")

    def test_find_tv_dir(self):
        from flinger.core.tvdetect import find_tv_dir
        # explicit flag only — labels/paths don't matter
        dirs = [{"label": "movies", "dir": "/downloads/movies"},
                {"label": "junk drawer", "dir": "/downloads/tv", "tv": True}]
        self.assertEqual(find_tv_dir(dirs), "/downloads/tv")
        self.assertIsNone(find_tv_dir([{"label": "tv", "dir": "/downloads/tv"}]))
        self.assertIsNone(find_tv_dir([]))


class TestConfig(unittest.TestCase):
    def test_urls(self):
        cfg = Config(host="nas", port=9091)
        self.assertEqual(cfg.rpc_url, "http://nas:9091/transmission/rpc")
        self.assertEqual(cfg.web_url, "http://nas:9091/transmission/web/")

    def test_config_dir_override_beats_the_platform_default(self):
        """The override must hold on macOS too, where XDG_CONFIG_HOME doesn't.

        Without it a test that saves a Config writes the real user's file.
        """
        from flinger.core.config import config_dir, config_path
        home = os.path.expanduser("~")
        self.assertFalse(str(config_dir()).startswith(home),
                         "tests must not resolve to a config dir under $HOME")

        # Restore whatever was there, not this module's CONFIG_DIR: `unittest
        # discover` (the documented invocation) imports the file both as
        # `test_core` and, via test_ui, as `tests.test_core`, and the two copies
        # have different CONFIG_DIRs. Putting back the wrong one leaves the rest
        # of the suite writing to a directory nothing reads.
        previous = os.environ["TORRENT_FLINGER_CONFIG_DIR"]
        with tempfile.TemporaryDirectory() as tmp:
            os.environ["TORRENT_FLINGER_CONFIG_DIR"] = tmp
            try:
                self.assertEqual(str(config_dir()), tmp)
                Config(host="written-by-a-test").save()
                self.assertTrue(config_path().exists())
                self.assertEqual(Config.load().host, "written-by-a-test")
            finally:
                os.environ["TORRENT_FLINGER_CONFIG_DIR"] = previous


if __name__ == "__main__":
    unittest.main()


class TestTrayIcon(unittest.TestCase):
    """Tray glyph selection. The macOS build implements the same four states
    and the same precedence in macos/.../Core/TrayIcon.swift — when a rule
    changes here, change it there and in UILogicTests.swift."""

    def test_precedence(self):
        from flinger.core.trayicon import ADDED, DOWNLOADING, ERROR, IDLE, tray_icon
        # A fresh add is a notification, not a status, so it outranks
        # everything for its three seconds — including a failed server.
        self.assertEqual(tray_icon(True, 0, True), ADDED)
        self.assertEqual(tray_icon(False, 0, True), ADDED)
        self.assertEqual(tray_icon(True, 9000, True), ADDED)

        self.assertEqual(tray_icon(False, 0, False), ERROR)
        # A stale speed from the last good poll must not mask a disconnect.
        self.assertEqual(tray_icon(False, 9000, False), ERROR)

        self.assertEqual(tray_icon(True, 1, False), DOWNLOADING)
        # The glyph is a down arrow; a seeding-only session shows the magnet.
        self.assertEqual(tray_icon(True, 0, False), IDLE)

    def test_assets_exist_for_every_state(self):
        from pathlib import Path

        from flinger.core.trayicon import ADDED_DURATION_S, STATES, asset_name
        assets = Path(__file__).resolve().parent.parent / "flinger" / "assets"
        for state in STATES:
            svg = assets / f"{asset_name(state)}.svg"
            self.assertTrue(svg.is_file(), f"missing shared asset {svg.name}")
        self.assertEqual(len(STATES), 4)
        # Must match TrayIcon.addedDuration on the macOS side.
        self.assertEqual(ADDED_DURATION_S, 3.0)


class TestFileTree(unittest.TestCase):
    """The Files tab's tree: folding Transmission's flat path list into
    directories, the aggregates each folder row shows, and resolving a
    selection of rows back to the file indices an RPC call takes. Mirrors
    macos/.../SelfTest/FileTreeTests.swift case for case — when a rule changes
    here, change it there."""

    @staticmethod
    def _stat(completed, wanted=1, priority=0):
        return {"bytesCompleted": completed, "wanted": wanted, "priority": priority}

    # Show/Season 1/ep1.mkv, Show/Season 1/subs/ep1.srt, Show/readme.txt
    SAMPLE = [{"name": "Show/Season 1/ep1.mkv", "length": 1000},
              {"name": "Show/Season 1/subs/ep1.srt", "length": 10},
              {"name": "Show/readme.txt", "length": 100}]

    def test_folds_paths_into_directories(self):
        from flinger.core.filetree import build_tree
        tree = build_tree(self.SAMPLE, [self._stat(1000), self._stat(10), self._stat(100)])
        self.assertEqual(len(tree), 1, "one root: every file shares the torrent's top folder")
        show = tree[0]
        self.assertEqual(show.name, "Show")
        self.assertTrue(show.is_directory)
        # A directory appears where its first file did, so the tree reads in
        # the order the server listed the files.
        self.assertEqual([c.name for c in show.children], ["Season 1", "readme.txt"])
        season = show.children[0]
        self.assertEqual([c.name for c in season.children], ["ep1.mkv", "subs"])
        self.assertEqual([c.name for c in season.children[1].children], ["ep1.srt"])
        self.assertFalse(show.children[1].is_directory, "a file has no children, so no triangle")

    def test_directories_aggregate_their_subtree(self):
        from flinger.core.filetree import build_tree
        show = build_tree(self.SAMPLE, [self._stat(500), self._stat(10), self._stat(0)])[0]
        self.assertEqual(show.length, 1110)
        self.assertEqual(show.completed, 510)
        self.assertEqual(show.done_percent, "46%")
        self.assertEqual(show.indices, [0, 1, 2], "checking a folder acts on every file under it")
        self.assertEqual(show.children[0].indices, [0, 1])
        self.assertEqual(show.children[0].length, 1010)

    def test_wanted_is_tri_state(self):
        from flinger.core.filetree import MIXED, OFF, ON, build_tree, toggled
        all_on = build_tree(self.SAMPLE, [self._stat(0)] * 3)
        self.assertEqual(all_on[0].wanted, ON)

        all_off = build_tree(self.SAMPLE, [self._stat(0, wanted=0)] * 3)
        self.assertEqual(all_off[0].wanted, OFF)

        some = build_tree(self.SAMPLE, [self._stat(0), self._stat(0, wanted=0),
                                        self._stat(0, wanted=0)])
        self.assertEqual(some[0].wanted, MIXED, "the root disagrees with itself")
        self.assertEqual(some[0].children[0].wanted, MIXED, "…and so does Season 1")
        self.assertEqual(some[0].children[1].wanted, OFF, "readme.txt alone is unambiguous")

        # A click on anything not fully checked checks it, which is the only
        # way out of mixed with one gesture.
        self.assertTrue(toggled(MIXED))
        self.assertTrue(toggled(OFF))
        self.assertFalse(toggled(ON))

    def test_priority_is_none_when_the_subtree_disagrees(self):
        from flinger.core.filetree import build_tree
        same = build_tree(self.SAMPLE, [self._stat(0, priority=1)] * 3)
        self.assertEqual(same[0].priority, 1)

        mixed = build_tree(self.SAMPLE, [self._stat(0, priority=1), self._stat(0), self._stat(0)])
        self.assertIsNone(mixed[0].priority, "the folder row has no single priority to show")
        self.assertEqual(mixed[0].children[1].priority, 0, "a file always has one")

    def test_selection_resolves_to_file_indices(self):
        from flinger.core.filetree import build_tree, indices_for
        tree = build_tree(self.SAMPLE, [self._stat(0)] * 3)
        show = tree[0]
        season, readme = show.children

        self.assertEqual(indices_for({readme.id}, tree), [2])
        self.assertEqual(indices_for({season.id}, tree), [0, 1],
                         "a folder stands for its whole subtree")
        # Selecting a folder and a file inside it must not send that file twice
        # — Transmission would take it, but the count in a confirmation would lie.
        self.assertEqual(indices_for({season.id, season.children[0].id}, tree), [0, 1])
        self.assertEqual(indices_for(set(), tree), [])
        self.assertEqual(indices_for({"nonexistent"}, tree), [])

    def test_single_file_torrents_and_short_filestats(self):
        from flinger.core.filetree import ON, build_tree
        # No directory component: one row, no triangle — the common case for a movie.
        flat = build_tree([{"name": "Movie.2026.mkv", "length": 42}], [self._stat(42)])
        self.assertEqual(len(flat), 1)
        self.assertFalse(flat[0].is_directory)
        self.assertEqual(flat[0].name, "Movie.2026.mkv")
        self.assertEqual(flat[0].indices, [0])

        # Some servers send fewer fileStats than files mid-metadata-fetch; the
        # missing ones take the documented defaults rather than dropping the rows.
        short = build_tree(self.SAMPLE, [self._stat(1000)])
        self.assertEqual(len(short[0].indices), 3)
        self.assertEqual(short[0].wanted, ON)
        self.assertEqual(short[0].completed, 1000)

        self.assertEqual(build_tree([], []), [])

    def test_ids_are_stable_and_unique(self):
        from flinger.core.filetree import build_tree
        first = build_tree(self.SAMPLE, [self._stat(0)] * 3)
        second = build_tree(self.SAMPLE, [self._stat(1)] * 3)
        # Refreshes rebuild the tree every few seconds; the ids have to survive
        # that or the tree would collapse under the user.
        self.assertEqual(first[0].id, second[0].id)
        self.assertEqual([c.id for c in first[0].children], [c.id for c in second[0].children])

        # A torrent that lists the same path twice still gets two rows.
        duplicated = build_tree([{"name": "a/x.bin", "length": 1},
                                 {"name": "a/x.bin", "length": 1}],
                                [self._stat(0), self._stat(0)])
        ids = [c.id for c in duplicated[0].children]
        self.assertEqual(len(ids), 2)
        self.assertEqual(len(set(ids)), 2, "duplicate paths must not collapse into one row")


class TestPolling(unittest.TestCase):
    """How often the popup refreshes. Linux-only — the macOS build has no idle
    slow-down — so there's no Swift counterpart to keep in step."""

    def test_a_hidden_popup_is_always_lazy(self):
        from flinger.core.polling import HIDDEN_POLL_MS, poll_interval_ms
        for slow in (True, False):
            for active in (True, False):
                self.assertEqual(
                    poll_interval_ms(1000, visible=False, active=active,
                                     slow_when_idle=slow), HIDDEN_POLL_MS,
                    "nobody is looking; only the tray glyph depends on this")

    def test_idle_slow_down_is_opt_out_and_only_applies_while_idle(self):
        from flinger.core.polling import IDLE_POLL_MS, poll_interval_ms
        self.assertEqual(poll_interval_ms(1000, True, active=False, slow_when_idle=True),
                         IDLE_POLL_MS)
        self.assertEqual(poll_interval_ms(1000, True, active=True, slow_when_idle=True),
                         1000, "something is moving, so the numbers have to keep up")
        self.assertEqual(poll_interval_ms(1000, True, active=False, slow_when_idle=False),
                         1000, "unchecked, the user's interval stands")

    def test_idle_never_speeds_the_interval_up(self):
        from flinger.core.polling import poll_interval_ms
        # Asking for 30s and being polled every 10s would be a surprise in the
        # wrong direction, so the slow-down is a floor, not a replacement.
        self.assertEqual(poll_interval_ms(30000, True, active=False, slow_when_idle=True),
                         30000)

    def test_active_means_downloading_or_verifying_not_seeding(self):
        from flinger.core.polling import any_active
        self.assertFalse(any_active([]))
        self.assertFalse(any_active([{"status": 0}]), "stopped")
        self.assertFalse(any_active([{"status": 6}, {"status": 5}]),
                         "a seed box would otherwise never go idle")
        self.assertTrue(any_active([{"status": 6}, {"status": 4}]), "downloading")
        self.assertTrue(any_active([{"status": 3}]), "queued to download")
        self.assertTrue(any_active([{"status": 2}]), "verifying moves a progress bar")
        self.assertTrue(any_active([{"status": 1}]), "queued to verify")
        self.assertFalse(any_active([{}]), "a torrent mid-metadata-fetch has no status")

    def test_the_config_key_defaults_on(self):
        from flinger.core.config import Config
        self.assertTrue(Config().slow_poll_when_idle)
