"""Config load/save. Pure stdlib — shared between Linux and macOS."""
from __future__ import annotations

import json
import os
import sys
from dataclasses import MISSING, asdict, dataclass, field
from pathlib import Path

APP_NAME = "torrent-flinger"


def config_dir() -> Path:
    # An explicit override wins on every platform. Tests and sandboxes need a
    # way to redirect this that works on macOS too: XDG_CONFIG_HOME doesn't,
    # since the macOS branch below (rightly) ignores it — which once let the
    # test suite overwrite a real user's config.
    override = os.environ.get("TORRENT_FLINGER_CONFIG_DIR")
    if override:
        return Path(override)
    if sys.platform == "darwin":
        return Path.home() / "Library" / "Application Support" / APP_NAME
    base = os.environ.get("XDG_CONFIG_HOME", str(Path.home() / ".config"))
    return Path(base) / APP_NAME


def config_path() -> Path:
    return config_dir() / "config.json"


@dataclass
class Config:
    protocol: str = "http"
    host: str = "localhost"
    port: int = 9091
    rpc_path: str = "/transmission/rpc"
    web_path: str = "/transmission/web/"
    username: str = ""
    password: str = ""
    verify_tls: bool = True

    notify_on_add: bool = True
    notify_on_finish: bool = True
    poll_interval_ms: int = 3000
    # Fall back to core.polling.IDLE_POLL_MS while nothing is downloading or
    # verifying. Unknown to the macOS build, which ignores it and keeps polling
    # at poll_interval_ms — a slower Linux poll is not a difference the shared
    # config has to reconcile.
    slow_poll_when_idle: bool = True

    start_paused: bool = False
    show_add_dialog: bool = True
    # [{"label": "TV", "dir": "/data/tv"}, ...]
    custom_dirs: list = field(default_factory=list)
    # Vestigial: the add dialog no longer preselects the last-used folder
    # (it always starts on the server default). Kept so older config files
    # still load unchanged.
    last_download_dir: str = ""
    # remote→local path mapping for "Reveal in Dolphin": where the server's
    # download share is mounted locally. Empty mount_remote = use the server's
    # default download-dir as the remote prefix.
    mount_remote: str = ""
    mount_local: str = ""

    @property
    def rpc_url(self) -> str:
        return f"{self.protocol}://{self.host}:{self.port}{self.rpc_path}"

    @property
    def web_url(self) -> str:
        return f"{self.protocol}://{self.host}:{self.port}{self.web_path}"

    @classmethod
    def load(cls) -> Config:
        try:
            data = json.loads(config_path().read_text())
        except (OSError, ValueError):
            return cls()
        return cls(**{k: v for k, v in data.items() if cls._usable(k, v)})

    @classmethod
    def _usable(cls, key: str, value) -> bool:
        """Whether a key is one we know, holding a value of the right type.

        Type matters as much as the name: a hand-edited `"poll_interval_ms":
        "3000"` would otherwise sail in as a string and fail somewhere far from
        the file — in the timer, or in the very dialog you'd fix it from. Each
        key falls back to its default instead, which is what the macOS build's
        decoder does key by key.
        """
        f = cls.__dataclass_fields__.get(key)
        if f is None:
            return False
        default = f.default_factory() if f.default is MISSING else f.default
        if isinstance(default, bool):
            return isinstance(value, bool)
        if isinstance(default, int):  # bools are ints; an interval of True isn't
            return isinstance(value, int) and not isinstance(value, bool)
        return isinstance(value, type(default))

    def save(self) -> None:
        config_dir().mkdir(parents=True, exist_ok=True)
        path = config_path()
        path.write_text(json.dumps(asdict(self), indent=2))
        os.chmod(path, 0o600)  # password lives in here
