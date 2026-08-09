"""Transmission RPC client.

Pure stdlib — no Qt imports. This module (and everything in flinger.core)
is shared verbatim between the Linux and macOS builds.

Protocol reference: https://github.com/transmission/transmission/blob/main/docs/rpc-spec.md
"""
from __future__ import annotations

import base64
import json
import ssl
import urllib.error
import urllib.request

# torrent-get "status" values
STATUS_STOPPED = 0
STATUS_CHECK_WAIT = 1
STATUS_CHECKING = 2
STATUS_DOWNLOAD_WAIT = 3
STATUS_DOWNLOADING = 4
STATUS_SEED_WAIT = 5
STATUS_SEEDING = 6

TORRENT_FIELDS = [
    "id",
    "name",
    "status",
    "percentDone",
    "metadataPercentComplete",
    "rateDownload",
    "rateUpload",
    "totalSize",
    "downloadedEver",
    "uploadedEver",
    "uploadRatio",
    "eta",
    "peersConnected",
    "peersSendingToUs",
    "peersGettingFromUs",
    "isFinished",
    "error",
    "errorString",
    "addedDate",
    "queuePosition",
    "sizeWhenDone",
    "leftUntilDone",
    "magnetLink",
    "downloadDir",
]

# extra fields fetched only for the details view of a single torrent
DETAIL_FIELDS = TORRENT_FIELDS + [
    "hashString",
    "magnetLink",
    "comment",
    "creator",
    "dateCreated",
    "doneDate",
    "activityDate",
    "downloadDir",
    "pieceCount",
    "pieceSize",
    "isPrivate",
    "haveValid",
    "haveUnchecked",
    "corruptEver",
    "desiredAvailable",
    "secondsDownloading",
    "secondsSeeding",
    "seedRatioLimit",
    "seedRatioMode",
    "uploadLimit",
    "uploadLimited",
    "downloadLimit",
    "downloadLimited",
    "peer-limit",
    "files",
    "fileStats",
    "peers",
    "trackerStats",
]


class TransmissionError(Exception):
    """Base error talking to the Transmission server."""


class ConnectionFailed(TransmissionError):
    pass


class AuthFailed(TransmissionError):
    pass


class TransmissionClient:
    def __init__(self, url: str, username: str = "", password: str = "",
                 timeout: float = 10.0, verify_tls: bool = True):
        self.url = url
        self.username = username
        self.password = password
        self.timeout = timeout
        self.verify_tls = verify_tls
        self._session_id = ""

    @classmethod
    def from_config(cls, cfg) -> TransmissionClient:
        return cls(cfg.rpc_url, cfg.username, cfg.password, verify_tls=cfg.verify_tls)

    def _call(self, method: str, arguments: dict | None = None, _retried: bool = False) -> dict:
        payload: dict = {"method": method}
        if arguments:
            payload["arguments"] = arguments
        headers = {
            "Content-Type": "application/json",
            "X-Transmission-Session-Id": self._session_id,
        }
        if self.username or self.password:
            token = base64.b64encode(f"{self.username}:{self.password}".encode()).decode()
            headers["Authorization"] = f"Basic {token}"
        req = urllib.request.Request(self.url, data=json.dumps(payload).encode(), headers=headers)
        ctx = None
        if self.url.startswith("https") and not self.verify_tls:
            ctx = ssl.create_default_context()
            ctx.check_hostname = False
            ctx.verify_mode = ssl.CERT_NONE
        try:
            with urllib.request.urlopen(req, timeout=self.timeout, context=ctx) as resp:
                body = json.loads(resp.read().decode("utf-8"))
        except urllib.error.HTTPError as e:
            if e.code == 409 and not _retried:
                # CSRF handshake: server hands us the session id to repeat the call with
                self._session_id = e.headers.get("X-Transmission-Session-Id", "")
                return self._call(method, arguments, _retried=True)
            if e.code in (401, 403):
                raise AuthFailed("authentication failed — check username/password") from e
            raise TransmissionError(f"HTTP {e.code}: {e.reason}") from e
        except (urllib.error.URLError, OSError) as e:
            reason = getattr(e, "reason", e)
            raise ConnectionFailed(str(reason)) from e
        if body.get("result") != "success":
            raise TransmissionError(body.get("result", "unknown error"))
        return body.get("arguments", {})

    # -- queries ------------------------------------------------------------

    def torrents(self) -> list[dict]:
        return self._call("torrent-get", {"fields": TORRENT_FIELDS}).get("torrents", [])

    def session_stats(self) -> dict:
        return self._call("session-stats")

    def session_get(self, fields: list[str] | None = None) -> dict:
        args = {"fields": fields} if fields else None
        return self._call("session-get", args)

    # -- actions ------------------------------------------------------------

    def set_turtle(self, enabled: bool) -> None:
        self._call("session-set", {"alt-speed-enabled": enabled})

    def add(self, link: str, download_dir: str | None = None, paused: bool = False) -> tuple[str, dict]:
        """Add a magnet URI or a local .torrent file path.

        Returns ("added" | "duplicate", {id, name, hashString}).
        """
        args: dict = {"paused": paused}
        if download_dir:
            args["download-dir"] = download_dir
        if link.startswith("magnet:"):
            args["filename"] = link
        else:
            with open(link, "rb") as f:
                args["metainfo"] = base64.b64encode(f.read()).decode()
        result = self._call("torrent-add", args)
        if "torrent-duplicate" in result:
            return "duplicate", result["torrent-duplicate"]
        return "added", result.get("torrent-added", {})

    def start(self, ids: list[int] | None = None) -> None:
        # ids=None means "all torrents" per the RPC spec; [] must stay a no-op
        if ids is not None and not ids:
            return
        self._call("torrent-start", {"ids": ids} if ids is not None else None)

    def stop(self, ids: list[int] | None = None) -> None:
        if ids is not None and not ids:
            return
        self._call("torrent-stop", {"ids": ids} if ids is not None else None)

    def remove(self, ids: list[int], delete_data: bool = False) -> None:
        self._call("torrent-remove", {"ids": ids, "delete-local-data": delete_data})

    # -- administration -----------------------------------------------------

    def torrent_details(self, torrent_id: int) -> dict:
        torrents = self._call(
            "torrent-get", {"ids": [torrent_id], "fields": DETAIL_FIELDS}
        ).get("torrents", [])
        if not torrents:
            raise TransmissionError(f"torrent {torrent_id} not found")
        return torrents[0]

    def torrent_set(self, ids: list[int], args: dict) -> None:
        """torrent-set passthrough: files-wanted/-unwanted, priority-high/
        -normal/-low (file indices), seedRatioLimit/Mode, uploadLimit(ed),
        downloadLimit(ed), labels, …"""
        self._call("torrent-set", {"ids": ids, **args})

    def set_location(self, ids: list[int], location: str, move: bool = True) -> None:
        self._call("torrent-set-location",
                   {"ids": ids, "location": location, "move": move})

    def verify(self, ids: list[int]) -> None:
        self._call("torrent-verify", {"ids": ids})

    def reannounce(self, ids: list[int]) -> None:
        self._call("torrent-reannounce", {"ids": ids})

    def queue_move(self, ids: list[int], where: str) -> None:
        """where: 'top' | 'up' | 'down' | 'bottom'"""
        if where not in ("top", "up", "down", "bottom"):
            raise ValueError(f"bad queue direction: {where}")
        self._call(f"queue-move-{where}", {"ids": ids})

    def free_space(self, path: str) -> int:
        return self._call("free-space", {"path": path}).get("size-bytes", -1)

    def session_set(self, args: dict) -> None:
        self._call("session-set", args)

    def port_test(self) -> bool:
        return bool(self._call("port-test").get("port-is-open"))
