import QtQuick
import Quickshell
import Quickshell.Io
import Quickshell.Wayland
import "components"

// oimmich — an Immich photo slideshow that takes the idle
// screensaver's place.
//
// Runs inside the Omarchy shell's long-lived Quickshell process, alongside the
// bar and the lock screen, so this file must never block: every network and
// image operation is a short-lived child process (scripts/immich.sh) and the
// QML only ever reads files that already exist on disk.
//
// No qs.Commons imports on purpose: the same file has to run under
// `quickshell -p .` for development, where Omarchy's import path is absent.
Item {
  id: root

  // Injected by omarchy-shell when installed as a plugin; null in dev.
  property var shell: null

  readonly property string home: Quickshell.env("HOME") || ""
  readonly property string pluginDir: {
    // Qt.resolvedUrl(".") may or may not carry a trailing slash depending on how
    // the shell was launched; normalise it so command paths cannot run together.
    var d = String(Qt.resolvedUrl(".")).replace(/^file:\/\//, "")
    return d.charAt(d.length - 1) === "/" ? d : d + "/"
  }
  readonly property string configPath: Quickshell.env("OIMMICH_CONFIG")
    || (home + "/.config/omarchy/oimmich/config.lua")
  // Lets the dev harness shorten the idle timer without touching the user config.
  readonly property var idleOverride: Quickshell.env("OIMMICH_IDLE_MS") || ""

  property var cfg: null
  property var meta: ({})
  property var manifest: []
  property var queue: []
  property var paths: ({})          // asset id -> cached file path
  property var pending: []          // asset ids waiting to be downloaded
  property string wanted: ""        // id the UI is waiting for
  property string current: ""       // file path on screen right now
  property string currentId: ""     // asset id of the file on screen
  property var captions: ({})       // asset id -> { date, place }
  property bool shown: false
  property bool sessionLocked: false
  // True once the overlay has been up long enough that input is real input: a
  // layer surface gets a synthetic hover/focus when it maps.
  property bool inputArmed: false
  property string lastEvent: "starting"

  readonly property string cacheDir: cfg && cfg.cache ? cfg.cache.dir : (home + "/.cache/oimmich")
  readonly property int prefetchCount: cfg && cfg.display ? Number(cfg.display.prefetch) || 0 : 3
  readonly property int fadeMs: cfg && cfg.display ? Number(cfg.display.crossfade_ms) || 0 : 1200
  readonly property int displayMs: cfg && cfg.display ? (Number(cfg.display.seconds_per_photo) || 30) * 1000 : 30000
  readonly property var currentCaption: (currentId !== "" && captions[currentId]) ? captions[currentId] : ({})
  readonly property string captionPlace: currentCaption.place || ""
  readonly property string captionDate: currentCaption.date
    ? Qt.formatDate(new Date(currentCaption.date), "d MMM yyyy") : ""
  readonly property int idleMs: idleOverride !== ""
    ? Number(idleOverride)
    : (cfg && cfg.display ? (Number(cfg.display.idle_seconds) || 0) * 1000 : 0)

  function logEvent(event) {
    lastEvent = event
    console.log("oimmich " + event)
  }

  // ---------------------------------------------------------------- lifecycle

  function start() {
    if (shown) return
    if (!manifest || manifest.length === 0) {
      logEvent("start-skipped: no-manifest")
      refreshManifest()
      return
    }
    shown = true
    inputArmed = false
    armTimer.restart()
    logEvent("shown")
    showNext()
    lockPollTimer.start()
  }

  function stop(reason) {
    if (!shown) return
    shown = false
    inputArmed = false
    lockPollTimer.stop()
    logEvent("hidden" + (reason ? ": " + reason : ""))
  }

  // ---------------------------------------------------------------- queueing

  function shuffled(list) {
    var a = list.slice(0)
    for (var i = a.length - 1; i > 0; i--) {
      var j = Math.floor(Math.random() * (i + 1))
      var t = a[i]; a[i] = a[j]; a[j] = t
    }
    return a
  }

  function refillQueue() {
    var ordered = manifest.map(function (a) { return a.id })
    queue = (cfg && cfg.display && cfg.display.order === "sequential") ? ordered : shuffled(ordered)
  }

  function showNext() {
    if (!shown) return
    if (queue.length === 0) refillQueue()
    if (queue.length === 0) { logEvent("queue-empty"); return }

    var id = queue.shift()
    wanted = id

    if (paths[id]) {
      current = paths[id]
      currentId = id
      logEvent("show-cached")
      fillPrefetch()
      return
    }

    if (pending.indexOf(id) === -1) pending.push(id)
    logEvent("show-waiting-for-download")
    fillPrefetch()
    pump()
  }

  // Keep `prefetch` photos ahead of the visible one: the crossfade must never
  // wait on a download, and downloads must not all run at once.
  function fillPrefetch() {
    var lookahead = queue.slice(0, prefetchCount)
    if (paths[wanted] === undefined && wanted !== "") lookahead.unshift(wanted)
    for (var i = 0; i < lookahead.length; i++) {
      var id = lookahead[i]
      if (paths[id] === undefined && pending.indexOf(id) === -1) pending.push(id)
    }
    pump()
  }

  function pump() {
    if (fetchProc.running || pending.length === 0) return
    var id = pending.shift()
    fetchProc.assetId = id
    fetchProc.running = true
  }

  // ---------------------------------------------------------------- processes

  Process {
    id: configProc
    command: ["lua", root.pluginDir + "scripts/config-to-json.lua", root.configPath]
    stderr: StdioCollector {
      waitForEnd: true
      onStreamFinished: {
        var msg = String(text).trim()
        if (msg !== "") console.log("oimmich config stderr: " + msg)
      }
    }
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: {
        var payload
        try {
          payload = JSON.parse(text)
        } catch (e) {
          console.log("oimmich config unreadable: " + e)
          return
        }
        root.meta = payload.meta || ({})

        // Hold the last good config when the new one has errors: a typo in the
        // Lua file must not blank the screensaver mid-run.
        if (root.meta.errors && root.meta.errors.length > 0) {
          console.log("oimmich config errors: " + root.meta.errors.join("; "))
          if (root.cfg) return
        }
        root.cfg = payload.config
        console.log("oimmich config loaded: idle=" + (payload.config.display.idle_seconds) + "s per=" + (payload.config.display.seconds_per_photo) + "s")

        if (root.meta.unknown && root.meta.unknown.length > 0) {
          console.log("oimmich unknown config keys: " + root.meta.unknown.join(", "))
        }
        root.refreshManifest()
      }
    }
  }

  function refreshManifest() {
    if (!cfg || manifestProc.running) return
    manifestProc.running = true
  }

  Process {
    id: manifestProc
    command: ["bash", root.pluginDir + "scripts/immich.sh", "list", root.configPath]
    stderr: StdioCollector {
      waitForEnd: true
      onStreamFinished: {
        var msg = String(text).trim()
        if (msg !== "") console.log("oimmich manifest stderr: " + msg)
      }
    }
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: {
        var list
        try {
          list = JSON.parse(text)
        } catch (e) {
          console.log("oimmich manifest unreadable: " + e)
          return
        }
        root.manifest = list
        root.refillQueue()
        console.log("oimmich manifest loaded: " + list.length + " photos")
        if (root.shown && root.current === "") root.showNext()
      }
    }
    onExited: function (code) {
    }
  }

  Process {
    id: fetchProc
    property string assetId: ""
    command: ["bash", root.pluginDir + "scripts/immich.sh", "fetch", root.configPath, assetId]
    stderr: StdioCollector {
      waitForEnd: true
      onStreamFinished: {
        var msg = String(text).trim()
        if (msg !== "") console.log("oimmich fetch stderr: " + msg)
      }
    }
    stdout: StdioCollector { id: fetchOut; waitForEnd: true }
    property string fetchedPath: ""

    onExited: function (code) {
      var lines = String(fetchOut.text || "").split("\n").map(function (l) { return l.trim() })
      var path = lines.length > 0 ? lines[0] : ""
      if (code === 0 && path !== "") {
        if (lines.length > 1 && lines[1] !== "") {
          try {
            var meta = JSON.parse(lines[1])
            var caps = root.captions
            caps[fetchProc.assetId] = meta
            root.captions = caps
          } catch (e) {
            // A caption is decoration: never let it break showing the photo.
          }
        }
        // Qt writes through a JS object: reassign so bindings notice.
        var next = root.paths
        next[fetchProc.assetId] = path
        root.paths = next

        if (root.shown && root.wanted === fetchProc.assetId) {
          root.current = path
          root.currentId = fetchProc.assetId
          root.logEvent("show-downloaded")
          root.fillPrefetch()
        }
      } else if (code === 3) {
        // Asset has no media (an AppleDouble stub or a broken import): drop it
        // and move on rather than stalling on the same id forever.
        root.logEvent("skip-missing-media")
        if (root.shown && root.wanted === fetchProc.assetId) root.showNext()
      } else {
        root.logEvent("fetch-failed:" + code)
        if (root.shown && root.wanted === fetchProc.assetId) root.showNext()
      }
      root.pump()
    }
  }

  Process {
    id: lockProc
    // No -q: quiet mode swallows stdout and every poll then reads "unlocked".
    command: ["bash", "-c", "omarchy-shell lock isLocked 2>/dev/null || echo false"]
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: {
        var locked = String(text || "").trim() === "true"
        root.sessionLocked = locked
        if (locked) root.stop("session-locked")
      }
    }
  }

  // ---------------------------------------------------------------- triggers

  Timer {
    id: configWatch
    interval: 1500
    repeat: true
    running: true
    // FileView is the documented way to watch, but the Lua config is read by a
    // child process anyway; polling its mtime is one stat every 1.5s.
    property string stamp: ""
    onTriggered: {
      stampProc.running = true
    }
  }

  Process {
    id: stampProc
    command: ["bash", "-c", "stat -Lc %Y:%s -- \"$1\" 2>/dev/null || echo missing", "_", root.configPath]
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: {
        var s = String(text || "").trim()
        if (configWatch.stamp === "") { configWatch.stamp = s; return }
        if (s !== configWatch.stamp) {
          configWatch.stamp = s
          configProc.running = true
        }
      }
    }
  }

  IdleMonitor {
    id: idle
    // Constant, never rebuilt: the run-up to the configured delay is timed
    // locally. Rebuilding this on config load left the monitor silent.
    timeout: 1
    respectInhibitors: true
    enabled: true
    onIsIdleChanged: {
      // Before the overlay is up, any activity cancels the run-up. Once it is
      // up, the compositor reports "active" simply because our own overlay
      // mapped, so dismissal is left to real key/pointer input.
      if (!isIdle) {
        runupTimer.stop()
      } else if (root.idleMs > 0 && !root.shown) {
        if (root.idleMs <= 1000) root.start()
        else {
          runupTimer.interval = root.idleMs - 1000
          runupTimer.restart()
        }
      }
    }
  }

  Timer {
    id: runupTimer
    repeat: false
    onTriggered: root.start()
  }

  Timer {
    id: armTimer
    // Long enough to outlast the hover/focus a layer surface receives when it
    // maps, and the second one it gets when the photo finishes loading.
    interval: 2000
    repeat: false
    onTriggered: root.inputArmed = true
  }

  Timer {
    id: advanceTimer
    interval: Math.max(1000, root.displayMs)
    repeat: true
    running: root.shown && root.current !== ""
    onTriggered: root.showNext()
  }

  Timer {
    id: lockPollTimer
    interval: 2000
    repeat: true
    running: false
    onTriggered: if (!lockProc.running) lockProc.running = true
  }

  Component.onCompleted: {
    configProc.running = true
    configWatch.running = true
  }

  // ---------------------------------------------------------------- surfaces

  // One layer-shell overlay per monitor, above normal windows. The session lock
  // draws above this, but it is cancelled outright when the session locks so no
  // timer keeps running behind the lock screen.
  Variants {
    model: Quickshell.screens

    PanelWindow {
      required property var modelData
      screen: modelData

      visible: root.shown
      color: "black"
      anchors { top: true; bottom: true; left: true; right: true }
      WlrLayershell.namespace: "oimmich"
      WlrLayershell.layer: WlrLayer.Overlay
      WlrLayershell.keyboardFocus: WlrKeyboardFocus.Exclusive
      exclusionMode: ExclusionMode.Ignore

      Crossfade {
        anchors.fill: parent
        imagePath: root.current
        fadeMs: root.fadeMs
        displayMs: root.displayMs
        fill: root.cfg && root.cfg.sizing ? root.cfg.sizing.fill : "blur"
        blurStrength: root.cfg && root.cfg.sizing ? Number(root.cfg.sizing.blur_strength) : 1.0
        darken: root.cfg && root.cfg.sizing ? Number(root.cfg.sizing.darken) : 0.08
        kenBurns: root.cfg && root.cfg.display ? !!root.cfg.display.ken_burns : true
      }

      Overlay {
        anchors.fill: parent
        showClock: root.cfg && root.cfg.overlay ? !!root.cfg.overlay.clock : false
        showDate: root.cfg && root.cfg.overlay ? !!root.cfg.overlay.date : false
        showCaption: root.cfg && root.cfg.overlay ? !!root.cfg.overlay.caption : false
        position: root.cfg && root.cfg.overlay && root.cfg.overlay.position
          ? String(root.cfg.overlay.position) : "bottom-left"
        captionPlace: root.captionPlace
        captionDate: root.captionDate
      }

      // Any key or pointer movement dismisses, the way the terminal screensaver
      // treats input: otherwise a stray overlay would leave the desktop hidden.
      Item {
        anchors.fill: parent
        focus: true
        Keys.onPressed: function (event) {
          if (!root.inputArmed) { event.accepted = true; return }
          root.stop("key")
          event.accepted = true
        }
      }

      MouseArea {
        anchors.fill: parent
        hoverEnabled: true
        // Mapping the surface, and again when the photo replaces the blank first
        // frame, both deliver a pointer position that the user never moved.
        // Dismiss only on sustained travel: several motion events, 40px total.
        property real lastX: -1
        property real lastY: -1
        property real travel: 0
        property int motions: 0

        onClicked: if (root.inputArmed) root.stop("click")
        onWheel: if (root.inputArmed) root.stop("wheel")
        onPositionChanged: function (mouse) {
          if (!root.inputArmed) return
          if (lastX < 0) { lastX = mouse.x; lastY = mouse.y; return }
          travel += Math.abs(mouse.x - lastX) + Math.abs(mouse.y - lastY)
          lastX = mouse.x
          lastY = mouse.y
          motions += 1
          if (travel > 40 && motions >= 3) root.stop("pointer")
        }
      }
    }
  }
}
