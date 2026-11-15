import QtQuick

// Text drawn over the photo: a clock, the date, and a caption for the photo
// itself. Kept deliberately quiet — a corner, small type, outlined so it stays
// readable against a bright sky or a dark frame.
//
// Pure QtQuick so the development harness can render it too.
Item {
  id: root

  property bool showClock: false
  property bool showDate: false
  property bool showCaption: false
  property string position: "bottom-left"   // bottom-left | bottom-right | top-left | top-right
  property string captionPlace: ""          // "Greenville, South Carolina"
  property string captionDate: ""           // already formatted, e.g. "14 Nov 2026"
  property color textColor: "#f4f4f4"
  property int margin: 36

  readonly property bool anyVisible: showClock || showDate || (showCaption && (captionPlace !== "" || captionDate !== ""))
  readonly property bool leftSide: position.indexOf("left") !== -1
  readonly property bool topSide: position.indexOf("top") !== -1

  visible: anyVisible && (showClock || showDate || captionPlace !== "" || captionDate !== "")
  opacity: anyVisible ? 1 : 0

  property var now: new Date()

  Timer {
    interval: 1000
    repeat: true
    running: root.showClock
    onTriggered: root.now = new Date()
  }

  function captionLine() {
    if (!root.showCaption) return ""
    if (root.captionDate !== "" && root.captionPlace !== "") return root.captionDate + "  ·  " + root.captionPlace
    if (root.captionDate !== "") return root.captionDate
    return root.captionPlace
  }

  Column {
    id: stack
    spacing: 2

    x: root.leftSide ? root.margin : root.width - width - root.margin
    y: root.topSide ? root.margin : root.height - height - root.margin

    Text {
      visible: root.showClock
      text: Qt.formatTime(root.now, "h:mm AP")
      color: root.textColor
      font.pixelSize: 40
      font.weight: Font.Medium
      style: Text.Outline
      styleColor: "#00000099"
    }

    Text {
      visible: root.showDate
      text: Qt.formatDate(root.now, "dddd d MMMM")
      color: root.textColor
      font.pixelSize: 20
      style: Text.Outline
      styleColor: "#00000099"
    }

    Text {
      visible: root.showCaption && text !== ""
      text: root.captionLine()
      color: root.textColor
      font.pixelSize: 18
      opacity: 0.92
      style: Text.Outline
      styleColor: "#00000099"
    }
  }
}
