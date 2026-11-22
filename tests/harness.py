#!/usr/bin/env python3
"""Run the plugin against the fake Immich and collect its event log.

One case is one throwaway config, one cache directory, one fake server and one
``quickshell -p <plugin>`` process, driven on a timeline:

    run_case("KEY-A", swap_to="KEY-B", swap_at=7)

Each case takes 15-25 seconds of wall clock and puts a full-screen overlay on
the desktop while it runs, because that is the only way to exercise the code
path that paints the photo. Do not run the suite mid-screenshot.

The plugin under test defaults to the repository this file lives in, and can be
pointed elsewhere with OIMMICH_TEST_PLUGIN (an installed copy, another checkout).

Events are the plugin's own ``oimmich <event>`` console lines, in order. Tests
assert on their order, which is the whole point: "hidden: library-empty never
happened after api-key-changed" is the bug, not "the string is absent".
"""
import os
import pathlib
import re
import shutil
import subprocess
import sys
import tempfile
import time

sys.path.insert(0, str(pathlib.Path(__file__).resolve().parent))
import fake_immich

REPO = pathlib.Path(__file__).resolve().parent.parent
PLUGIN = pathlib.Path(os.environ.get("OIMMICH_TEST_PLUGIN", REPO))
QUICKSHELL = shutil.which("quickshell")

EVENT = re.compile(r"oimmich (.*)$")

CONFIG = """return {{
  server = {{ url = "http://127.0.0.1:{port}", api_key_file = "{key}" }},
  source = {{ mode = "newest" }},
  display = {{ order = "sequential", seconds_per_photo = 3, prefetch = {prefetch},
               crossfade_ms = 200, idle_seconds = 0 }},
  cache = {{ dir = "{cache}" }},
}}
"""


class Case:
    """The result of one run: the event stream and the raw log."""

    def __init__(self, events, log):
        self.events = events
        self.log = log

    def index(self, prefix):
        """Index of the first event starting with `prefix`, or -1."""
        for i, event in enumerate(self.events):
            if event.startswith(prefix):
                return i
        return -1

    def count(self, prefix):
        return sum(1 for event in self.events if event.startswith(prefix))

    def after(self, prefix, start=0):
        """Events from `start` that begin with `prefix`."""
        return [e for e in self.events[start:] if e.startswith(prefix)]

    def tail(self, n=25):
        return "\n".join(self.events[-n:])


def parse_events(text):
    events = []
    for line in text.splitlines():
        match = EVENT.search(line)
        if match:
            events.append(match.group(1).strip())
    return events


def run_case(key="KEY-A", swap_to=None, swap_at=None, slow=0.0, touch_at=None,
             evict_at=None, duration=16.0, prefetch=0, plugin=None):
    """Drive one timeline and return a Case.

    key        the key file's contents at start
    swap_to    rewrite the key file to this at swap_at seconds
    slow       delay every list response, to keep one in flight across a swap
    touch_at   touch config.lua at this time (a config edit that changes nothing)
    evict_at   delete every cached image at this time
    duration   how long the plugin runs
    """
    plugin = pathlib.Path(plugin or PLUGIN)
    if QUICKSHELL is None:
        raise RuntimeError("quickshell is not on PATH")
    if not (plugin / "shell.qml").exists():
        raise RuntimeError("%s does not look like the plugin (no shell.qml)" % plugin)

    server, port = fake_immich.start(slow=slow)
    tmp = pathlib.Path(tempfile.mkdtemp(prefix="oimmich-test-"))
    try:
        cache = tmp / "cache"
        cache.mkdir()
        key_file = tmp / "key"
        key_file.write_text(key + "\n")
        config = tmp / "config.lua"
        config.write_text(CONFIG.format(port=port, key=key_file, cache=cache,
                                        prefetch=prefetch))

        env = dict(os.environ,
                   OIMMICH_CONFIG=str(config),
                   OIMMICH_FORCE_SHOW="1",
                   QT_ASSUME_STDERR_HAS_CONSOLE="1")

        proc = subprocess.Popen([QUICKSHELL, "-p", str(plugin)],
                                env=env, stdout=subprocess.PIPE,
                                stderr=subprocess.STDOUT, text=True)

        actions = []
        if touch_at is not None:
            actions.append((touch_at, lambda: os.utime(config, None)))
        if swap_at is not None and swap_to is not None:
            actions.append((swap_at, lambda: key_file.write_text(swap_to + "\n")))
        if evict_at is not None:
            actions.append((evict_at, lambda: [p.unlink() for p in (cache / "img").glob("*")
                                               if p.is_file()] if (cache / "img").exists() else None))
        actions.sort(key=lambda a: a[0])

        start = time.monotonic()
        for when, action in actions:
            remaining = when - (time.monotonic() - start)
            if remaining > 0:
                time.sleep(remaining)
            action()
        remaining = duration - (time.monotonic() - start)
        if remaining > 0:
            time.sleep(remaining)

        proc.terminate()
        try:
            out, _ = proc.communicate(timeout=10)
        except subprocess.TimeoutExpired:
            proc.kill()
            out, _ = proc.communicate()
        return Case(parse_events(out or ""), out or "")
    finally:
        server.shutdown()
        server.server_close()
        shutil.rmtree(tmp, ignore_errors=True)
