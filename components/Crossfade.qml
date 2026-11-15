import QtQuick

// Two photo layers that cross-dissolve. Swapping `source` on a single Image
// flashes a blank frame while the new file decodes, so the outgoing photo stays
// up until the incoming one is ready and only then fades over it.
Item {
  id: root

  property string imagePath: ""
  property int fadeMs: 1200
  property int displayMs: 30000
  property string fill: "blur"
  property color solidColor: "#0d0d0d"
  property real blurStrength: 1.0
  property real darken: 0.08
  property bool kenBurns: true

  // Which layer is on top right now. The other one is free for the next photo.
  property bool showingA: true
  property string pathA: ""
  property string pathB: ""
  // Emitted once a crossfade completes, so the caller can prefetch ahead.
  signal shown(string path)

  readonly property string visiblePath: showingA ? pathA : pathB

  function show(path) {
    if (!path || path === visiblePath) return
    // Load into the hidden layer, then flip: the fade does the rest.
    if (showingA) pathB = path
    else pathA = path
    showingA = !showingA
    settleTimer.restart()
    shown(path)
  }

  onImagePathChanged: show(imagePath)

  // Free the layer that has just been covered, so memory holds one photo, not a
  // slideshow's worth.
  Timer {
    id: settleTimer
    interval: Math.max(0, root.fadeMs) + 50
    onTriggered: {
      if (root.showingA) root.pathB = ""
      else root.pathA = ""
    }
  }

  Slide {
    id: slideA
    anchors.fill: parent
    source: root.pathA
    fill: root.fill
    solidColor: root.solidColor
    blurStrength: root.blurStrength
    darken: root.darken
    kenBurns: root.kenBurns ? 0.05 : 0
    kenBurnsMs: root.displayMs + root.fadeMs
    running: root.showingA
    opacity: root.showingA ? 1 : 0
    Behavior on opacity {
      NumberAnimation { duration: Math.max(0, root.fadeMs); easing.type: Easing.InOutQuad }
    }
  }

  Slide {
    id: slideB
    anchors.fill: parent
    source: root.pathB
    fill: root.fill
    solidColor: root.solidColor
    blurStrength: root.blurStrength
    darken: root.darken
    kenBurns: root.kenBurns ? 0.05 : 0
    kenBurnsMs: root.displayMs + root.fadeMs
    running: !root.showingA
    opacity: root.showingA ? 0 : 1
    Behavior on opacity {
      NumberAnimation { duration: Math.max(0, root.fadeMs); easing.type: Easing.InOutQuad }
    }
  }
}
