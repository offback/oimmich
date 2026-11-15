import QtQuick
import QtQuick.Window
import "components"

// Development harness only, not part of the installed plugin: opens a plain Qt
// window the size of the monitor's logical area and cycles cached previews
// through the same Crossfade/Slide components the overlay uses.
Window {
  id: win
  width: 1200
  height: 675
  visible: true
  visibility: Window.FullScreen
  color: "black"
  title: "oimmich preview"

  property var list: []
  property int idx: -1

  Component.onCompleted: {
    var xhr = new XMLHttpRequest()
    xhr.open("GET", "file:///tmp/preview-list.json", false)
    xhr.send()
    try {
      list = JSON.parse(xhr.responseText)
    } catch (e) {
      console.error("preview list unreadable: " + e)
    }
    if (list.length > 0) idx = 0
  }

  Crossfade {
    id: xf
    anchors.fill: parent
    fadeMs: 1200
    displayMs: 5000
    kenBurns: true
    imagePath: win.idx >= 0 && win.list.length > 0 ? win.list[win.idx] : ""
  }

  Timer {
    interval: 5000
    repeat: true
    running: win.list.length > 0
    onTriggered: win.idx = (win.idx + 1) % win.list.length
  }

  // Esc closes the harness; the real overlay dismisses on any input.
  Shortcut {
    sequence: "Escape"
    onActivated: Qt.quit()
  }
}
