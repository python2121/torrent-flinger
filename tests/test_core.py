"""Core tests against a mock Transmission RPC server (409 handshake included).

Run: .venv/bin/python -m unittest discover tests
"""
import base64
import json
import threading
import unittest
from http.server import BaseHTTPRequestHandler, HTTPServer

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


if __name__ == "__main__":
    unittest.main()
