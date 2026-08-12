"""Offscreen UI tests: popup grouping/filtering/expansion, dialogs, and the
full app loop against the mock RPC server.

Run (from linux/): PYTHONPATH=. .venv/bin/python -m unittest discover tests
"""
import os
import threading
import unittest
from http.server import HTTPServer

os.environ.setdefault("QT_QPA_PLATFORM", "offscreen")

from PySide6.QtCore import Qt
from PySide6.QtTest import QTest
from PySide6.QtWidgets import QApplication

# Importing test_core redirects TORRENT_FLINGER_CONFIG_DIR at a throwaway
# directory, which several tests here need: they save a Config as a side effect
# (AddDialog remembers the last download directory, the options dialog writes on
# apply) and would otherwise overwrite the real user's config on macOS, where
# config_dir() ignores XDG_CONFIG_HOME.
from tests.test_core import CONFIG_DIR, MockRPC


def wait_until(condition, timeout_ms=3000, step_ms=50):
    """Process events until condition() is true or timeout; returns success."""
    waited = 0
    while waited <= timeout_ms:
        if condition():
            return True
        QTest.qWait(step_ms)
        waited += step_ms
    return condition()


def _torrent(tid, name, status, done=0.5, **kw):
    base = {"id": tid, "name": name, "status": status, "percentDone": done,
            "metadataPercentComplete": 1, "rateDownload": 0, "rateUpload": 0,
            "totalSize": 1_000_000, "eta": -1, "uploadRatio": 0.5,
            "errorString": "", "peersConnected": 2, "downloadDir": "/data",
            "magnetLink": "magnet:?xt=urn:btih:x", "sizeWhenDone": 1_000_000}
    base.update(kw)
    return base


# A multi-file torrent as the Files tab has to draw it: nested directories, and
# a subtree the user has partly deselected so the folder rows go mixed.
NESTED_FILES = {
    "files": [{"name": "Show/Season 1/ep1.mkv", "length": 1000},
              {"name": "Show/Season 1/subs/ep1.srt", "length": 10},
              {"name": "Show/readme.txt", "length": 100}],
    "fileStats": [{"bytesCompleted": 500, "wanted": 1, "priority": 0},
                  {"bytesCompleted": 10, "wanted": 0, "priority": 1},
                  {"bytesCompleted": 0, "wanted": 1, "priority": 0}],
}


class PopupTest(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.app = QApplication.instance() or QApplication([])

    def make_popup(self):
        from flinger.ui.popup import Popup
        popup = Popup()
        torrents = [
            _torrent(1, "ubuntu.iso", 4, 0.4, rateDownload=1_200_000, eta=3600),
            _torrent(2, "fedora.iso", 6, 1.0, rateUpload=88_000),
            _torrent(3, "arch.iso", 0, 1.0),
            _torrent(4, "broken.iso", 0, 0.2, errorString="tracker error"),
        ]
        popup.set_data(torrents, {"downloadSpeed": 1_200_000, "uploadSpeed": 88_000},
                       free_space=42_000_000_000, server="nas")
        return popup, torrents

    def test_grouping(self):
        popup, _ = self.make_popup()
        labels = [h.label.text() for h in popup._section_headers]
        self.assertEqual(labels, ["Error · 1", "Downloading · 1",
                                  "Seeding · 1", "Finished · 1"])
        self.assertEqual(len(popup._rows), 4)
        self.assertIn("42.0 GB free", popup.footer_stats.text())
        self.assertIn("Connected", popup.status_label.text())

    def test_filter(self):
        popup, _ = self.make_popup()
        popup.search.setText("fedora")
        visible = [tid for tid, row in popup._rows.items() if not row.isHidden()]
        self.assertEqual(visible, [2])
        visible_headers = [h.label.text() for h in popup._section_headers
                           if not h.isHidden()]
        self.assertEqual(visible_headers, ["Seeding · 1"])
        popup.search.setText("")
        self.assertTrue(all(not r.isHidden() for r in popup._rows.values()))

    def test_incremental_update_keeps_rows(self):
        popup, torrents = self.make_popup()
        row_before = popup._rows[1]
        torrents[0]["percentDone"] = 0.9
        popup.set_data(torrents, {})
        self.assertIs(popup._rows[1], row_before)          # same widget, updated
        # remove one torrent → row goes away, groups re-laid out
        popup.set_data(torrents[:2], {})
        self.assertEqual(set(popup._rows), {1, 2})

    def test_row_expansion(self):
        popup, _ = self.make_popup()
        popup.show()
        row = popup._rows[1]
        self.assertEqual(row.body.maximumHeight(), 0)
        row.toggle_expanded()
        self.assertTrue(wait_until(lambda: row.body.maximumHeight() > 0))
        self.assertEqual(row._detail_values["Peers"].text(), "2")
        self.assertEqual(row._detail_values["Status"].text(), "Downloading")
        row.toggle_expanded()
        self.assertTrue(wait_until(lambda: row.body.maximumHeight() == 0))
        popup.hide()

    def test_error_state(self):
        from flinger.ui.popup import Popup
        popup = Popup()
        popup.set_error("Can't reach nas — connection refused")
        self.assertIn("Disconnected", popup.status_label.text())
        self.assertIn("Can't reach", popup.placeholder.text())

    def test_clipboard_banner(self):
        popup, _ = self.make_popup()
        QApplication.clipboard().setText("magnet:?xt=urn:btih:abc&dn=Cool+File")
        popup._maybe_offer_clip()
        self.assertFalse(popup.clip_banner.isHidden())
        self.assertIn("Cool File", popup.clip_label.text())
        added = []
        popup.add_link.connect(added.append)
        popup._add_clip_now()
        self.assertEqual(added, ["magnet:?xt=urn:btih:abc&dn=Cool+File"])
        self.assertTrue(popup.clip_banner.isHidden())
        popup._maybe_offer_clip()  # same text now dismissed → no banner
        self.assertTrue(popup.clip_banner.isHidden())

    def test_selection_semantics(self):
        popup, _ = self.make_popup()
        order = popup._visual_order()
        self.assertEqual(len(order), 4)
        # plain click selects only that row
        popup._on_row_clicked(order[0], Qt.NoModifier)
        self.assertEqual(popup.selected_ids(), [order[0]])
        self.assertTrue(popup._rows[order[0]].is_selected)
        # ctrl-click toggles another into the selection
        popup._on_row_clicked(order[2], Qt.ControlModifier)
        self.assertEqual(set(popup.selected_ids()), {order[0], order[2]})
        # shift-click ranges from the last anchor (order[2]) to the end
        popup._on_row_clicked(order[3], Qt.ShiftModifier)
        self.assertEqual(set(popup.selected_ids()), {order[2], order[3]})
        # plain click collapses back to a single selection
        popup._on_row_clicked(order[1], Qt.NoModifier)
        self.assertEqual(popup.selected_ids(), [order[1]])

    def test_body_click_selects_not_expands(self):
        popup, _ = self.make_popup()
        popup.show()
        row = popup._rows[1]
        QTest.mousePress(row, Qt.LeftButton, Qt.NoModifier,
                         row._header_widget.geometry().center())
        QTest.mouseRelease(row, Qt.LeftButton, Qt.NoModifier,
                           row._header_widget.geometry().center())
        self.assertEqual(row.body.maximumHeight(), 0)     # did not expand
        self.assertTrue(row.is_selected)                  # did select
        # chevron still expands
        row.chevron.click()
        self.assertTrue(wait_until(lambda: row.body.maximumHeight() > 0))
        popup.hide()

    def test_context_menu_contents(self):
        popup, _ = self.make_popup()
        popup._on_row_clicked(1, Qt.NoModifier)
        single = [a.text() for a in popup._build_context_menu([1]).actions()
                  if a.text()]
        self.assertIn("Details…", single)
        self.assertIn("Resume", single)
        self.assertIn("Remove…", single)
        multi = [a.text() for a in popup._build_context_menu([1, 2, 3]).actions()
                 if a.text()]
        self.assertIn("Pause (3)", multi)
        self.assertIn("Copy magnet links", multi)
        self.assertNotIn("Details…", multi)
        # right-click on an unselected row reselects to just that row
        popup._on_row_context = popup._on_row_context  # (exec not called in tests)
        got = []
        popup.remove_many.connect(lambda ids, d: got.append((list(ids), d)))
        popup.remove_many.emit([1, 2], True)
        self.assertEqual(got, [([1, 2], True)])

    def test_reveal_in_dolphin_entry(self):
        popup, _ = self.make_popup()   # rows have downloadDir "/data"
        popup._exists = lambda path: path.startswith("/run/media/nas")
        # no mapping configured → no reveal entry
        actions = [a.text() for a in popup._build_context_menu([1]).actions()]
        self.assertNotIn("Reveal in Dolphin", actions)
        popup.set_path_mapping("/data", "/run/media/nas")
        actions = [a.text() for a in popup._build_context_menu([1]).actions()]
        self.assertIn("Reveal in Dolphin", actions)
        self.assertEqual(popup._local_path_for(1), "/run/media/nas")
        # when the torrent's own folder exists, reveal targets the item itself
        popup._exists_any = lambda path: path == "/run/media/nas/ubuntu.iso"
        self.assertEqual(popup._reveal_paths(1),
                         ("/run/media/nas", "/run/media/nas/ubuntu.iso"))
        # content not there yet → falls back to just the directory
        popup._exists_any = lambda path: False
        self.assertEqual(popup._reveal_paths(1), ("/run/media/nas", ""))
        # multi-selection → no reveal entry
        actions = [a.text() for a in popup._build_context_menu([1, 2]).actions()]
        self.assertNotIn("Reveal in Dolphin", actions)
        # local mount missing entirely → entry hidden even with mapping set
        popup._exists = lambda path: False
        actions = [a.text() for a in popup._build_context_menu([1]).actions()]
        self.assertNotIn("Reveal in Dolphin", actions)

    def test_add_dir_dialog(self):
        from flinger.ui.options_dialog import AddDirDialog
        dialog = AddDirDialog()
        self.assertFalse(dialog._save_btn.isEnabled())     # empty dir → no Save
        dialog.dir_edit.setText("/data/movies")
        self.assertTrue(dialog._save_btn.isEnabled())
        dialog.label_edit.setText("Movies")
        self.assertEqual(dialog.dir_edit.text(), "/data/movies")

    def test_options_roundtrip_mount(self):
        from flinger.core.config import Config
        from flinger.ui.options_dialog import OptionsDialog
        cfg = Config(mount_remote="/data", mount_local="/mnt/nas",
                     last_download_dir="/data/tv")
        dialog = OptionsDialog(cfg)
        out = dialog.to_config()
        self.assertEqual(out.mount_remote, "/data")
        self.assertEqual(out.mount_local, "/mnt/nas")
        self.assertEqual(out.last_download_dir, "/data/tv")  # carried through

    def test_options_roundtrip_refresh(self):
        from flinger.core.config import Config
        from flinger.ui.options_dialog import POLL_CHOICES, OptionsDialog
        dialog = OptionsDialog(Config(poll_interval_ms=5000, slow_poll_when_idle=False))
        self.assertEqual(dialog.poll.currentData(), 5000)
        self.assertFalse(dialog.slow_idle.isChecked())
        dialog.slow_idle.setChecked(True)
        out = dialog.to_config()
        self.assertEqual(out.poll_interval_ms, 5000)
        self.assertTrue(out.slow_poll_when_idle)

        # An interval nothing on the menu offers — a hand-edited config — is
        # kept rather than rounded to a neighbour the user didn't pick.
        odd = OptionsDialog(Config(poll_interval_ms=4500))
        self.assertEqual(odd.poll.currentData(), 4500)
        self.assertEqual(odd.poll.currentText(), "4.5s")
        self.assertEqual(odd.poll.count(), len(POLL_CHOICES) + 1)
        self.assertEqual(odd.to_config().poll_interval_ms, 4500)

    def test_escape_clears_search_then_closes(self):
        popup, _ = self.make_popup()
        popup.show()
        popup.search.setText("fedora")
        QTest.keyClick(popup, Qt.Key_Escape)
        self.assertEqual(popup.search.text(), "")      # first Esc clears search
        self.assertTrue(popup.isVisible())
        QTest.keyClick(popup, Qt.Key_Escape)
        self.assertFalse(popup.isVisible())            # second Esc closes
        # Esc typed while the search field itself has focus behaves the same
        popup.show()
        popup.search.setFocus()
        popup.search.setText("arch")
        QTest.keyClick(popup.search, Qt.Key_Escape)
        self.assertEqual(popup.search.text(), "")
        self.assertTrue(popup.isVisible())
        popup.hide()

    def test_escape_clears_selection_first(self):
        popup, _ = self.make_popup()
        popup.show()
        popup.search.setText("iso")                    # matches every row
        popup._on_row_clicked(1, Qt.NoModifier)
        popup._on_row_clicked(2, Qt.ControlModifier)
        self.assertEqual(sorted(popup.selected_ids()), [1, 2])

        QTest.keyClick(popup, Qt.Key_Escape)           # selection goes first…
        self.assertEqual(popup.selected_ids(), [])
        self.assertFalse(popup._rows[1].is_selected)
        self.assertEqual(popup.search.text(), "iso")   # …search survives it
        self.assertTrue(popup.isVisible())

        QTest.keyClick(popup, Qt.Key_Escape)           # …then the search…
        self.assertEqual(popup.search.text(), "")
        self.assertTrue(popup.isVisible())

        QTest.keyClick(popup, Qt.Key_Escape)           # …then the popup itself
        self.assertFalse(popup.isVisible())

        # A selection the filter has hidden doesn't swallow a press: the search
        # goes first, bringing the still-selected rows back into view.
        popup.show()
        popup._on_row_clicked(1, Qt.NoModifier)        # ubuntu.iso
        popup.search.setText("arch")                   # …now hidden
        self.assertEqual(popup.selected_ids(), [])
        QTest.keyClick(popup, Qt.Key_Escape)
        self.assertEqual(popup.search.text(), "")
        self.assertEqual(popup.selected_ids(), [1])
        QTest.keyClick(popup, Qt.Key_Escape)
        self.assertEqual(popup.selected_ids(), [])
        self.assertTrue(popup.isVisible())

        # Cleared selection also resets the cursor: Down starts at the top.
        popup.show()
        popup._on_row_clicked(3, Qt.NoModifier)
        popup.clear_selection()
        popup.step_selection(1)
        self.assertEqual(popup.selected_ids(), [popup._visual_order()[0]])
        popup.hide()

    def test_action_button_modes(self):
        popup, _ = self.make_popup()
        rows = popup._rows
        self.assertEqual(rows[1].toggle_btn.text(), "Pause")    # downloading 40%
        self.assertEqual(rows[2].toggle_btn.text(), "✕")        # seeding, 100%
        self.assertEqual(rows[3].toggle_btn.text(), "✕")        # finished
        self.assertEqual(rows[2]._btn_mode, "remove")
        # ✕ box and chevron share the same footprint
        self.assertEqual(rows[2].toggle_btn.minimumSize(), rows[2].chevron.minimumSize())
        self.assertEqual(rows[2].toggle_btn.maximumSize(), rows[2].chevron.maximumSize())
        self.assertEqual(rows[4].toggle_btn.text(), "Resume")   # paused at 20%
        self.assertEqual(rows[1].toggle_btn.styleSheet(), "")           # plain
        self.assertIn("27ae60", rows[4].toggle_btn.styleSheet())        # green outline
        self.assertIn("da4453", rows[2].toggle_btn.styleSheet())        # red outline

    def test_remove_button_skips_confirmation(self):
        popup, _ = self.make_popup()
        removed = []
        popup.remove_clicked.connect(lambda tid, data: removed.append((tid, data)))
        popup._rows[2].toggle_btn.click()   # ✕ on a completed torrent
        # No dialog to dismiss: the signal has already fired, keeping the data.
        self.assertEqual(removed, [(2, False)])

    def test_arrow_keys_walk_the_list(self):
        from PySide6.QtTest import QTest
        popup, _ = self.make_popup()
        popup.show()
        order = popup._visual_order()          # Error, Downloading, Seeding, Finished
        # Sent to the search field, where focus lives: a single-line QLineEdit
        # ignores Up/Down, so they bubble up to the popup.
        QTest.keyClick(popup.search, Qt.Key_Down)
        self.assertEqual(popup._selected_ids, {order[0]})
        QTest.keyClick(popup.search, Qt.Key_Down)
        self.assertEqual(popup._selected_ids, {order[1]})
        QTest.keyClick(popup.search, Qt.Key_Up)
        self.assertEqual(popup._selected_ids, {order[0]})
        self.assertTrue(popup._rows[order[0]].is_selected)
        QTest.keyClick(popup.search, Qt.Key_Up)                 # clamps at the top
        self.assertEqual(popup._selected_ids, {order[0]})
        for _ in order:
            QTest.keyClick(popup.search, Qt.Key_Down)
        self.assertEqual(popup._selected_ids, {order[-1]})      # and at the bottom

    def test_shift_arrow_extends_the_selection(self):
        from PySide6.QtTest import QTest
        popup, _ = self.make_popup()
        popup.show()
        order = popup._visual_order()
        QTest.keyClick(popup.search, Qt.Key_Down)               # start at the top
        QTest.keyClick(popup.search, Qt.Key_Down, Qt.ShiftModifier)
        self.assertEqual(popup._selected_ids, set(order[:2]))
        QTest.keyClick(popup.search, Qt.Key_Down, Qt.ShiftModifier)
        self.assertEqual(popup._selected_ids, set(order[:3]))
        self.assertEqual(popup._anchor_id, order[0])            # anchor stays put
        # Reversing shrinks the same range rather than starting a new one.
        QTest.keyClick(popup.search, Qt.Key_Up, Qt.ShiftModifier)
        self.assertEqual(popup._selected_ids, set(order[:2]))
        # A plain arrow collapses back to a single row.
        QTest.keyClick(popup.search, Qt.Key_Down)
        self.assertEqual(popup._selected_ids, {order[2]})

    def test_arrow_keys_skip_filtered_rows(self):
        popup, _ = self.make_popup()
        popup.search.setText("iso")            # everything matches
        popup.step_selection(1)
        first = popup._visual_order()[0]
        popup.search.setText("fedora")         # anchor row now hidden
        popup.step_selection(1)
        self.assertEqual(popup._selected_ids, {2})
        self.assertNotEqual(first, 2)

    def test_row_subtitle_content(self):
        popup, _ = self.make_popup()
        self.assertIn("↓ 1.2 MB/s", popup._rows[1].subtitle_label.text())
        self.assertIn("40%", popup._rows[1].subtitle_label.text())
        self.assertIn("ratio 0.50", popup._rows[2].subtitle_label.text())
        self.assertIn("tracker error", popup._rows[4].subtitle_label.text())


class DetailsDialogTest(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.app = QApplication.instance() or QApplication([])
        cls.server = HTTPServer(("127.0.0.1", 0), MockRPC)
        threading.Thread(target=cls.server.serve_forever, daemon=True).start()

    @classmethod
    def tearDownClass(cls):
        cls.server.shutdown()

    def _dialog(self):
        from flinger.core.transmission import TransmissionClient
        from flinger.ui.details_dialog import DetailsDialog
        client = TransmissionClient(
            f"http://127.0.0.1:{self.server.server_address[1]}/rpc")
        return DetailsDialog(client, 1, "test.iso")

    def test_details_populates_and_edits(self):
        dialog = self._dialog()
        self.assertTrue(
            wait_until(lambda: dialog._info["Hash"].text() == "abc123"),
            f"details never populated: hash={dialog._info['Hash'].text()!r} "
            f"error={dialog._info['Error'].text()!r}")
        self.assertEqual(dialog.files.topLevelItemCount(), 1)
        self.assertEqual(dialog.peers.rowCount(), 1)
        self.assertEqual(dialog.trackers.item(0, 0).text(), "tracker.example.org")
        # unchecking a file must send files-unwanted with its index
        dialog.files.topLevelItem(0).setCheckState(0, Qt.Unchecked)
        self.assertTrue(wait_until(
            lambda: any(c[0] == "torrent-set" and c[1].get("files-unwanted") == [0]
                        for c in MockRPC.calls)),
            [c for c in MockRPC.calls if c[0] == "torrent-set"])
        dialog.timer.stop()
        dialog.close()

    def test_files_tab_is_a_directory_tree(self):
        dialog = self._dialog()
        self.assertTrue(wait_until(lambda: dialog._info["Hash"].text() == "abc123"))
        # The mock's torrent has one file; drive the tree with a nested one
        # instead of waiting for a refresh to overwrite it.
        dialog.timer.stop()
        dialog._populate_files(NESTED_FILES)

        self.assertEqual(dialog.files.topLevelItemCount(), 1)
        show = dialog.files.topLevelItem(0)
        self.assertEqual(show.text(0), "Show")
        self.assertEqual([show.child(i).text(0) for i in range(show.childCount())],
                         ["Season 1", "readme.txt"])
        # Folder rows aggregate their subtree and go partial when it disagrees.
        self.assertEqual(show.text(1), "1.1 KB")
        self.assertEqual(show.text(2), "46%")
        self.assertEqual(show.checkState(0), Qt.PartiallyChecked)
        self.assertEqual(show.text(3), "Mixed")
        self.assertEqual(show.child(1).checkState(0), Qt.Checked)
        self.assertEqual(show.child(1).text(3), "Normal")
        # Folders start collapsed so a huge torrent opens as one line…
        self.assertFalse(show.isExpanded())
        show.setExpanded(True)
        # …and a refresh must not fold them back up under the user.
        dialog._populate_files(NESTED_FILES)
        self.assertTrue(dialog.files.topLevelItem(0).isExpanded())

        # Checking a folder acts on every file underneath it, in one call.
        dialog.files.topLevelItem(0).setCheckState(0, Qt.Checked)
        self.assertTrue(wait_until(
            lambda: any(c[0] == "torrent-set" and c[1].get("files-wanted") == [0, 1, 2]
                        for c in MockRPC.calls)),
            [c for c in MockRPC.calls if c[0] == "torrent-set"])
        dialog.timer.stop()
        dialog.close()

    def test_detail_columns_are_draggable_and_fill_the_view(self):
        from PySide6.QtWidgets import QHeaderView
        dialog = self._dialog()
        dialog.timer.stop()
        dialog.resize(700, 560)
        dialog.show()
        QTest.qWait(50)
        headers = [dialog.files.header(), dialog.peers.horizontalHeader(),
                   dialog.trackers.horizontalHeader()]
        for tab, header in enumerate(headers, start=1):
            # A hidden tab page gets its resize event only when it's first
            # shown, so a header is laid out at the moment you look at it.
            dialog.tabs.setCurrentIndex(tab)
            QTest.qWait(30)
            for column in range(header.count()):
                # Stretch would fill the view but nail the section in place.
                self.assertEqual(header.sectionResizeMode(column),
                                 QHeaderView.Interactive, f"column {column}")
            self.assertAlmostEqual(
                sum(header.sectionSize(c) for c in range(header.count())),
                header.width(), delta=2, msg="no dead space to the right")

        # Dragging any divider hands the layout to the user for good: a later
        # resize must not shove their column back.
        dialog.tabs.setCurrentIndex(1)
        header = dialog.files.header()
        header.resizeSection(1, 250)
        widths = [header.sectionSize(c) for c in range(header.count())]
        dialog.resize(1000, 560)
        QTest.qWait(50)
        self.assertEqual([header.sectionSize(c) for c in range(header.count())], widths)
        dialog.close()

    def test_add_dialog_flow(self):
        from flinger.core.config import Config
        from flinger.ui.add_dialog import AddDialog
        cfg = Config(custom_dirs=[{"label": "TV", "dir": "/data/tv"}])
        dialog = AddDialog(cfg, "Some.Torrent")
        # Default first, then customs only — no "New Directory" entry
        self.assertEqual(dialog.location.itemText(0), "< Default Directory >")
        self.assertEqual(dialog.location.itemData(1), "/data/tv")
        self.assertEqual(dialog.location.count(), 2)
        dialog.location.setCurrentIndex(1)
        directory, _paused = dialog.result_options()
        self.assertEqual(directory, "/data/tv")

    def test_add_dialog_tv_autodetect(self):
        from flinger.core.config import Config
        from flinger.ui.add_dialog import AddDialog
        cfg = Config(custom_dirs=[{"label": "movies", "dir": "/downloads/movies"},
                                  {"label": "tv", "dir": "/downloads/tv", "tv": True}],
                     last_download_dir="/downloads/movies")
        # TV name → flagged dir wins, even over last-used
        dialog = AddDialog(cfg, "The.Bear.S03E05.1080p.WEB.h264")
        self.assertEqual(dialog.location.currentData(), "/downloads/tv")
        self.assertFalse(dialog.tv_hint.isHidden())
        # movie name → last-used behavior unchanged, no hint
        dialog = AddDialog(cfg, "Oppenheimer.2023.1080p.BluRay")
        self.assertEqual(dialog.location.currentData(), "/downloads/movies")
        self.assertTrue(dialog.tv_hint.isHidden())
        # TV name but no dir flagged → default, no hint (labels don't count)
        cfg2 = Config(custom_dirs=[{"label": "tv", "dir": "/downloads/tv"}])
        dialog = AddDialog(cfg2, "Severance.S02E01.2160p")
        self.assertIsNone(dialog.location.currentData())
        self.assertTrue(dialog.tv_hint.isHidden())

    def test_options_tv_flag_exclusive(self):
        from PySide6.QtCore import Qt

        from flinger.core.config import Config
        from flinger.ui.options_dialog import OptionsDialog
        cfg = Config(custom_dirs=[{"label": "tv", "dir": "/d/tv", "tv": True},
                                  {"label": "books", "dir": "/d/books"}])
        dialog = OptionsDialog(cfg)
        self.assertEqual(dialog.dirs.item(0, 2).checkState(), Qt.CheckState.Checked)
        # checking another row unchecks the first (radio semantics)
        dialog.dirs.item(1, 2).setCheckState(Qt.CheckState.Checked)
        self.assertEqual(dialog.dirs.item(0, 2).checkState(), Qt.CheckState.Unchecked)
        out = dialog.to_config()
        self.assertEqual(out.custom_dirs,
                         [{"label": "tv", "dir": "/d/tv"},
                          {"label": "books", "dir": "/d/books", "tv": True}])

    def test_add_dialog_preselects_last_dir(self):
        from flinger.core.config import Config
        from flinger.ui.add_dialog import AddDialog
        cfg = Config(custom_dirs=[{"label": "TV", "dir": "/data/tv"},
                                  {"label": "Books", "dir": "/data/books"}],
                     last_download_dir="/data/books")
        dialog = AddDialog(cfg, "Some.Torrent")
        self.assertEqual(dialog.location.currentData(), "/data/books")


class AppIntegrationTest(unittest.TestCase):
    """Full loop: FlingerApp polls the mock server, popup populates, links add."""

    @classmethod
    def setUpClass(cls):
        cls.app = QApplication.instance() or QApplication([])
        cls.server = HTTPServer(("127.0.0.1", 0), MockRPC)
        threading.Thread(target=cls.server.serve_forever, daemon=True).start()
        import json
        # TORRENT_FLINGER_CONFIG_DIR (set at import) is the only redirection
        # that works on both platforms — XDG_CONFIG_HOME is Linux-only.
        with open(os.path.join(CONFIG_DIR, "config.json"), "w") as f:
            json.dump({"host": "127.0.0.1", "port": cls.server.server_address[1],
                       "rpc_path": "/rpc", "show_add_dialog": False,
                       "notify_on_add": False, "poll_interval_ms": 1000}, f)

    @classmethod
    def tearDownClass(cls):
        cls.server.shutdown()

    def test_app_polls_and_adds(self):
        from flinger.ui.app import FlingerApp
        flinger = FlingerApp(self.app)
        try:
            self.assertTrue(wait_until(lambda: len(flinger.popup._rows) == 1),
                            "poll never populated the popup")
            row = next(iter(flinger.popup._rows.values()))
            self.assertEqual(row._t["name"], "test.iso")
            self.assertIn("Connected", flinger.popup.status_label.text())
            self.assertIn("free", flinger.popup.footer_stats.text())

            before = len([c for c in MockRPC.calls if c[0] == "torrent-add"])
            flinger.handle_link("magnet:?xt=urn:btih:abc&dn=new.iso")
            self.assertTrue(wait_until(
                lambda: len([c for c in MockRPC.calls if c[0] == "torrent-add"]) > before),
                "link was never added")
            added = [c for c in MockRPC.calls if c[0] == "torrent-add"][-1]
            self.assertEqual(added[1]["filename"], "magnet:?xt=urn:btih:abc&dn=new.iso")

            # turtle mode now lives in the options dialog, applied on save
            from flinger.ui.options_dialog import OptionsDialog
            dialog = OptionsDialog(flinger.config)   # no client → no live load
            dialog._load_session({"alt-speed-enabled": False})
            dialog.alt_enabled.setChecked(True)
            flinger._apply_options(dialog)
            self.assertTrue(wait_until(
                lambda: any(c[0] == "session-set" and c[1].get("alt-speed-enabled")
                            for c in MockRPC.calls)))
        finally:
            flinger.timer.stop()
            flinger.tray.hide()

    def test_poll_interval_follows_the_popup_and_activity(self):
        from flinger.core.polling import HIDDEN_POLL_MS, IDLE_POLL_MS
        from flinger.ui.app import FlingerApp
        flinger = FlingerApp(self.app)
        try:
            self.assertTrue(wait_until(lambda: len(flinger.popup._rows) == 1),
                            "poll never populated the popup")
            # Closed popup: polling only keeps the tray glyph and tooltip honest.
            self.assertEqual(flinger.timer.interval(), HIDDEN_POLL_MS)
            flinger.popup.show()
            # The mock's torrent is downloading, so the user's rate applies.
            self.assertTrue(wait_until(lambda: flinger.timer.interval() == 1000),
                            f"interval stayed at {flinger.timer.interval()}")
            flinger._active = False
            flinger._apply_poll_interval()
            self.assertEqual(flinger.timer.interval(), IDLE_POLL_MS,
                             "nothing moving, so back off")
            flinger.config.slow_poll_when_idle = False
            flinger._apply_poll_interval()
            self.assertEqual(flinger.timer.interval(), 1000, "unchecked, the setting stands")
        finally:
            flinger.timer.stop()
            flinger.popup.hide()
            flinger.tray.hide()


if __name__ == "__main__":
    unittest.main()
