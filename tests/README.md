# Tests

Behaviour tests for the paths where the plugin could show something it should
not. They drive the real plugin in a real `quickshell` against a fake Immich, and
assert on the plugin's own event log, because the bug in each case is *what is
left on the screen* — something a unit test on a QML function cannot see.

```bash
python3 -m unittest discover -s tests -v
```

Requirements: `python3` (stdlib only), `quickshell`, and a Wayland session.
Cases are skipped, not failed, when either is missing.

**Each case puts a full-screen overlay on your desktop with exclusive keyboard
focus for 15–25 seconds.** The whole suite is about 90 seconds. Run it when you
can leave the machine alone.

## What each case guards

| Case | The bug it would catch |
| --- | --- |
| `test_swap_to_empty_account_hides_the_slideshow` | A key swap to an account with no photos left the previous account's photo on screen until input, lock or quit (`queue-empty` on every tick, no `hidden`). |
| `test_swap_to_another_account_replaces_the_photo` | The same swap to an account *with* photos must replace the photo rather than blank the screen — and must not stop the slideshow. |
| `test_swap_during_an_inflight_refresh_is_retried` | The key-change notification was consumed before the refresh was requested, and `refreshManifest()` returns while a list is running: a swap landing mid-list was dropped and the old library applied for up to an hour. |
| `test_config_edit_without_a_library_change_keeps_the_photo` | The other direction: an ordinary refresh must not drop a photo that is still in the library. |
| `test_deleted_cache_files_are_refetched` | The account-switch fix shares the "clear the display" machinery with the decode path, so an evicted cached file must still be re-fetched instead of leaving a black frame. |

## How it works

`fake_immich.py` serves one library per API key — two photos for `KEY-A`, none
for `KEY-B`, one for `KEY-C` — over the two endpoints `scripts/immich.sh` uses.
Because the plugin authenticates with `x-api-key`, swapping the *contents* of the
key file swaps the account, exactly as it does against a real server. `--slow`
delays the first page of every list, which is how the in-flight race is
reproduced.

`harness.py` runs one case: a throwaway config and cache directory, the fake
server on an ephemeral port, and `quickshell -p <plugin>` with
`OIMMICH_FORCE_SHOW=1`. A small timeline does the interesting things at the
interesting moments (`swap_at`, `touch_at`, `evict_at`), then the run is stopped
and its `oimmich <event>` lines are returned in order.

`Case` exposes `index(prefix)`, `count(prefix)` and `after(prefix, start)` so a
test can say "no `show-*` event after `hidden`" instead of "the string is
absent".

## Do the tests actually bite?

Point the harness at an older checkout and watch them fail:

```bash
mkdir -p /tmp/oimmich-0.1.2 && git archive v0.1.2 | tar -x -C /tmp/oimmich-0.1.2
OIMMICH_TEST_PLUGIN=/tmp/oimmich-0.1.2 python3 -m unittest discover -s tests -v
# Ran 5 tests ... FAILED (failures=3)
```

A test that has never failed is not evidence of anything.

## Adding a case

```python
case = harness.run_case("KEY-A", swap_to="KEY-C", swap_at=7, duration=16)
self.assertGreaterEqual(case.index("drop-stale-photo"), 0, case.tail())
```

`duration` must outlast the last action plus a couple of seconds; the plugin's
config/key watch polls every 1.5 s, so allow for that margin. `case.tail()` in
the assertion message is what turns a red test into a diagnosis.
