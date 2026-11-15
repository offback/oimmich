import QtQuick
import QtQuick.Effects

// One photo, full-bleed, with no black bars: the same image is drawn twice —
// cropped and blurred underneath, fitted on top. A portrait on a landscape
// screen therefore gets blurred side panels instead of empty space, and a wide
// photo on a tall screen gets blurred top and bottom bands.
//
// Pure QtQuick on purpose: no Omarchy/Quickshell imports, so this file can be
// rendered in a plain Qt window while developing and reused verbatim inside the
// shell plugin.
Item {
  id: root

  property string source: ""
  // "blur" (default) | "black" | "solid"
  property string fill: "blur"
  property color solidColor: "#0d0d0d"
  property real blurStrength: 0.8
  property real darken: 0.12

  // Ken Burns: extra scale reached over kenBurnsMs while running.
  property real kenBurns: 0.05
  property int kenBurnsMs: 30000
  property bool running: true

  readonly property bool ready: fg.status === Image.Ready
  readonly property bool blurred: fill === "blur"

  clip: true

  Rectangle {
    anchors.fill: parent
    visible: !root.blurred
    color: root.fill === "black" ? "black" : root.solidColor
  }

  // Under-layer: cropped to cover. Decoded at reduced size on purpose — it is
  // about to be blurred, so full resolution there is wasted memory and time.
  Image {
    id: bg
    anchors.fill: parent
    visible: root.blurred
    source: root.source
    fillMode: Image.PreserveAspectCrop
    asynchronous: false
    cache: false
    smooth: true
    sourceSize.width: Math.max(1, Math.min(Math.round(root.width * 0.5), 2048))
    sourceSize.height: Math.max(1, Math.min(Math.round(root.height * 0.5), 2048))
  }

  MultiEffect {
    anchors.fill: bg
    source: bg
    visible: root.blurred && bg.status === Image.Ready
    blurEnabled: true
    blur: root.blurStrength
    blurMax: 96
    blurMultiplier: 1.25
    brightness: -root.darken
    contrast: -root.darken * 0.5
  }

  // Over-layer: the whole photo, nothing cropped.
  Image {
    id: fg
    anchors.fill: parent
    source: root.source
    fillMode: Image.PreserveAspectFit
    asynchronous: false
    cache: false
    smooth: true
    sourceSize.width: Math.round(root.width)
    sourceSize.height: Math.round(root.height)
    transformOrigin: Item.Center
    scale: 1.0
  }

  NumberAnimation on scale {
    target: fg
    property: "scale"
    running: root.kenBurns > 0 && root.running && fg.status === Image.Ready
    from: 1.0
    to: 1.0 + root.kenBurns
    duration: Math.max(2000, root.kenBurnsMs)
    easing.type: Easing.InOutSine
  }
}
