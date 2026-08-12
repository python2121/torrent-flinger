"""The torrent's file list as a directory tree, for the Files tab.

Transmission hands back a flat list of paths (``"Super Nintendo/Chrono
Trigger.zip"``), which for a 678-file torrent is unreadable and impossible to
act on in bulk. Folding it into directories is pure list arithmetic, so it lives
here rather than in the dialog: :func:`build_tree` is the whole feature, and the
tree widget only draws it.

Ported from ``macos/Sources/TorrentFlinger/Core/FileTree.swift`` — same ids,
same ordering, same tri-state rules, with matching tests on both sides. When a
rule changes here, change it there.
"""
from __future__ import annotations

from dataclasses import dataclass

# Whether the files underneath a row are set to download. Files are only ever
# on or off; a directory is mixed when its subtree disagrees.
ON = "on"
OFF = "off"
MIXED = "mixed"


def toggled(wanted: str) -> bool:
    """What a click does: anything not fully checked becomes checked."""
    return wanted != ON


@dataclass
class FileNode:
    """One row of the Files tab: a file, or a directory standing for its subtree."""

    #: Stable across refreshes and unique even if a torrent lists the same path
    #: twice: files key off their index, directories off their path.
    id: str
    #: Just this level's component — the row shows the tree, not the path.
    name: str
    #: Every file index in this subtree, in server order. A file has exactly
    #: one; a directory has all of its descendants', which is what makes
    #: checking or prioritizing a whole folder one RPC call.
    indices: list[int]
    length: int
    completed: int
    wanted: str
    #: None when the files underneath disagree.
    priority: int | None
    #: None for files — the tree widget uses this to decide what gets a
    #: disclosure triangle.
    children: list[FileNode] | None

    @property
    def is_directory(self) -> bool:
        return self.children is not None

    @property
    def done_percent(self) -> str:
        return f"{self.completed / max(self.length, 1) * 100:.0f}%"


def build_tree(files: list[dict], stats: list[dict]) -> list[FileNode]:
    """Fold ``files``/``fileStats`` into a tree, preserving server order: a
    directory appears where its first file did, and files keep their original
    order within it. Missing ``fileStats`` entries fall back to the documented
    default (wanted, normal priority), same as the flat list did.
    """
    root = _Builder("", "")
    for index, f in enumerate(files):
        stat = stats[index] if index < len(stats) else {}
        components = [c for c in f.get("name", "").split("/") if c]
        node = root
        for component in components[:-1]:
            node = node.directory(component)
        leaf = _Builder(components[-1] if components else "(unnamed)", f"f{index}")
        leaf.file = (index, int(f.get("length", 0) or 0), stat)
        node.children.append(leaf)
    return [child.build() for child in root.children]


def indices_for(ids: set[str], nodes: list[FileNode]) -> list[int]:
    """The file indices behind a set of selected rows, deduplicated and in
    server order — selecting a folder and one of its files must not send that
    file twice.
    """
    found: set[int] = set()

    def walk(node: FileNode) -> None:
        if node.id in ids:
            found.update(node.indices)
            return
        for child in node.children or ():
            walk(child)

    for node in nodes:
        walk(node)
    return sorted(found)


class _Builder:
    """Mutable scaffolding: a trie that remembers insertion order, collapsed
    into immutable-in-practice `FileNode`s once every file has been placed.
    """

    __slots__ = ("children", "directories", "file", "name", "path")

    def __init__(self, name: str, path: str):
        self.name = name
        self.path = path
        self.children: list[_Builder] = []
        # Directory children by name, so placing a file stays O(depth).
        self.directories: dict[str, _Builder] = {}
        self.file: tuple[int, int, dict] | None = None

    def directory(self, component: str) -> _Builder:
        existing = self.directories.get(component)
        if existing is not None:
            return existing
        child = _Builder(component, component if not self.path else f"{self.path}/{component}")
        self.directories[component] = child
        self.children.append(child)
        return child

    def build(self) -> FileNode:
        if self.file is not None:
            index, length, stat = self.file
            return FileNode(
                id=self.path, name=self.name, indices=[index], length=length,
                completed=int(stat.get("bytesCompleted", 0) or 0),
                # wanted is serialized as 0/1, not boolean — treat as truthy
                wanted=ON if stat.get("wanted", 1) else OFF,
                priority=int(stat.get("priority") or 0), children=None)
        built = [child.build() for child in self.children]
        if all(child.wanted == ON for child in built):
            wanted = ON
        elif all(child.wanted == OFF for child in built):
            wanted = OFF
        else:
            wanted = MIXED
        priorities = {child.priority for child in built}
        return FileNode(
            id=f"d:{self.path}", name=self.name,
            indices=[i for child in built for i in child.indices],
            length=sum(child.length for child in built),
            completed=sum(child.completed for child in built),
            wanted=wanted,
            priority=priorities.pop() if len(priorities) == 1 else None,
            children=built)
