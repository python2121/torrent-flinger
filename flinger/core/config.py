"""Config load/save. Pure stdlib — shared between Linux and macOS."""
from __future__ import annotations

import json
import os
import sys
from dataclasses import asdict, dataclass, field
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

    start_paused: bool = False
    show_add_dialog: bool = True
    # [{"label": "TV", "dir": "/data/tv"}, ...]
    custom_dirs: list = field(default_factory=list)
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
        known = {f for f in cls.__dataclass_fields__}
        return cls(**{k: v for k, v in data.items() if k in known})

    def save(self) -> None:
        config_dir().mkdir(parents=True, exist_ok=True)
        path = config_path()
        path.write_text(json.dumps(asdict(self), indent=2))
        os.chmod(path, 0o600)  # password lives in here
