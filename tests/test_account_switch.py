#!/usr/bin/env python3
"""Behaviour tests for the account-switch paths, against a fake Immich.

Run with:

    python3 -m unittest discover -s tests -v

Each test starts a full-screen overlay for the duration of one case (15-25 s),
because the thing under test is what is on the screen. Five cases, about two
minutes. Skip on a machine without quickshell or a Wayland session.
"""
import os
import shutil
import unittest

import harness

SKIP = None
if shutil.which("quickshell") is None:
    SKIP = "quickshell is not on PATH"
elif not os.environ.get("WAYLAND_DISPLAY"):
    SKIP = "no Wayland session to draw on"
SKIP_REASON = SKIP or ""


class AccountSwitch(unittest.TestCase):
    """A key swap must not leave the previous account's photo on screen."""

    @unittest.skipIf(SKIP is not None, SKIP_REASON)
    def test_swap_to_empty_account_hides_the_slideshow(self):
        # The reported bug: the refresh succeeds, the new library is empty, and
        # the old photo used to stay up until the user touched the keyboard.
        case = harness.run_case("KEY-A", swap_to="KEY-B", swap_at=7, duration=16)

        self.assertGreaterEqual(case.index("shown"), 0, case.tail())
        changed = case.index("api-key-changed")
        self.assertGreaterEqual(changed, 0, "the key change was never noticed\n" + case.tail())

        hidden = case.index("hidden: library-empty")
        self.assertGreaterEqual(hidden, 0, "the slideshow never stopped\n" + case.tail())
        self.assertLess(case.index("library-empty"), hidden, case.tail())

        # nothing may be shown after the stop: that would be the stale photo
        self.assertEqual(
            [e for e in case.events[hidden:] if e.startswith("show")], [],
            "a photo was shown after the library came back empty\n" + case.tail())

    @unittest.skipIf(SKIP is not None, SKIP_REASON)
    def test_swap_to_another_account_replaces_the_photo(self):
        # A non-empty new library must replace the photo, not blank the screen.
        case = harness.run_case("KEY-A", swap_to="KEY-C", swap_at=7, duration=16)

        dropped = case.index("drop-stale-photo")
        self.assertGreaterEqual(dropped, 0, "the old photo was never reconsidered\n" + case.tail())
        self.assertEqual(case.count("hidden"), 0, "the slideshow stopped with photos available\n"
                         + case.tail())

        # the new library has one photo, and it must be displayed
        shown_after = case.after("show-downloaded", dropped) + case.after("show-cached", dropped)
        self.assertTrue(shown_after, "the replacement photo never appeared\n" + case.tail())

    @unittest.skipIf(SKIP is not None, SKIP_REASON)
    def test_swap_during_an_inflight_refresh_is_retried(self):
        # Regression: the key stamp was consumed before the refresh was requested,
        # and refreshManifest() returns while a list is running, so a swap landing
        # mid-list was dropped and the old library was applied for up to an hour.
        case = harness.run_case("KEY-A", swap_to="KEY-B", swap_at=9, slow=5,
                                touch_at=8, duration=26)

        changed = case.index("api-key-changed")
        self.assertGreaterEqual(changed, 0, case.tail())

        # The in-flight (old key) list still lands, and then the latched refresh
        # must run and find the empty library.
        loads = [i for i, e in enumerate(case.events) if e.startswith("manifest loaded:")]
        after_change = [i for i in loads if i > changed]
        self.assertGreaterEqual(len(after_change), 2,
                                "no refresh was re-issued after the in-flight one\n" + case.tail())
        self.assertTrue(case.events[after_change[-1]].startswith("manifest loaded: 0"),
                        case.tail())
        self.assertGreaterEqual(case.index("hidden: library-empty"), 0, case.tail())

    @unittest.skipIf(SKIP is not None, SKIP_REASON)
    def test_config_edit_without_a_library_change_keeps_the_photo(self):
        # The membership check must not fire on an ordinary refresh: same library,
        # same photo, nothing to do.
        case = harness.run_case("KEY-A", touch_at=7, duration=16)

        self.assertGreaterEqual(case.count("config loaded"), 2, case.tail())
        self.assertEqual(case.count("drop-stale-photo"), 0,
                         "a refresh dropped a photo that was still in the library\n" + case.tail())
        self.assertEqual(case.count("hidden"), 0, case.tail())

    @unittest.skipIf(SKIP is not None, SKIP_REASON)
    def test_deleted_cache_files_are_refetched(self):
        # The decode path shares the "clear the display" machinery with the
        # account switch, so it is guarded here too: an evicted file must be
        # re-fetched, not left as a black frame.
        case = harness.run_case("KEY-A", evict_at=6, duration=16, prefetch=1)

        failed = case.index("image-unreadable:")
        self.assertGreaterEqual(failed, 0, "the eviction was not noticed\n" + case.tail())
        self.assertTrue(case.after("show-downloaded", failed),
                        "nothing was re-fetched after the file vanished\n" + case.tail())
        self.assertEqual(case.count("hidden"), 0, case.tail())


if __name__ == "__main__":
    unittest.main(verbosity=2)
