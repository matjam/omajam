pragma ComponentBehavior: Bound

import QtQuick
import qs.Commons

// The play queue, with the cover beside it.
//
// The queue is the one list the service already holds -- the bar's label wants
// its length whether or not this panel exists -- so this pane binds to it
// rather than fetching anything. Everything it does is a command: play this
// row, drop that one, move this one up.
//
// The cover is here rather than in the panel's frame because that is where rmpc
// puts it, and because it is the tab where a picture of what is playing has
// something to do with what is on screen.
Item {
  id: root

  property var service: null
  property bool active: false

  property string fontFamily: Style.font.family
  property int fontSize: Style.font.bodySmall
  property color foreground: Color.popups.text
  property color accent: Color.accent

  readonly property color rule: Qt.rgba(foreground.r, foreground.g, foreground.b, 0.12)
  readonly property var list: queueList

  readonly property var rows: service ? service.queue : []
  readonly property int playingIndex: service ? service.queuePosition : -1

  // ------------------------------------------------------------- actions

  function activate() {
    var row = queueList.currentRow
    if (!service || !row) return
    if (row.id !== undefined) service.playId(Number(row.id))
    else service.playPosition(queueList.currentIndex)
  }

  function deleteSelected() {
    if (!service) return
    var rows = queueList.targetRows()
    for (var i = 0; i < rows.length; i++) {
      if (rows[i].id !== undefined) service.removeId(Number(rows[i].id))
    }
    queueList.clearMarks()
  }

  function deleteAll() { if (service) service.clearQueue() }
  function shuffle() { if (service) service.shuffleQueue() }
  function crop() { if (service) service.cropQueue() }

  // Move the row under the cursor, and follow it: the point of holding K is to
  // walk one song up the queue, which means the cursor has to walk with it.
  function moveBy(delta) {
    if (!service) return
    var from = queueList.currentIndex
    var to = from + delta
    if (from < 0 || to < 0 || to >= queueList.count) return
    service.moveSong(from, to)
    queueList.moveTo(to)
  }

  function jumpToCurrent() {
    if (playingIndex < 0) return
    queueList.moveTo(playingIndex)
    queueList.centerCursor()
  }

  // Opening the panel on a queue of nine hundred should show the song that is
  // playing, not the first one added.
  //
  // Armed rather than done, because opening can win the race against the queue
  // arriving: the panel may be up a few milliseconds before the rows are, and a
  // jump to song 340 of a queue that is still empty lands on row 0. The flag
  // survives until there is something to jump to, and any move of the cursor
  // disarms it -- once the user has driven, the panel stops steering.
  property bool pendingJump: false

  onActiveChanged: {
    if (!active) return
    pendingJump = true
    Qt.callLater(tryJump)
  }

  onRowsChanged: if (pendingJump) Qt.callLater(tryJump)
  onPlayingIndexChanged: if (pendingJump) Qt.callLater(tryJump)

  function tryJump() {
    if (!pendingJump || !active) return
    if (playingIndex < 0 || rows.length === 0) return
    pendingJump = false
    jumpToCurrent()
  }

  // --------------------------------------------------------------- layout

  Row {
    anchors.fill: parent
    spacing: 0

    Item {
      id: artPane
      // Never more than a third of the panel: the queue is the thing being read
      // here, and a cover is square whatever room it is given.
      width: Math.min(Math.round(root.width * 0.34), root.height)
      height: parent.height

      Item {
        // Square, and at the top of its column rather than centred in it, so
        // the eye finds it in the same place whatever shape the panel is.
        anchors { top: parent.top; left: parent.left; right: parent.right }
        anchors.rightMargin: Style.space(10)
        height: Math.min(width, artPane.height)

        Image {
          id: cover
          anchors.fill: parent
          visible: status === Image.Ready
          source: root.service ? root.service.artSource : ""
          fillMode: Image.PreserveAspectFit
          asynchronous: true
          cache: true
          // Decoded at roughly the size it is drawn: a 3000px scan decoded in
          // full would cost tens of megabytes to show at 300.
          sourceSize.width: 600
        }

        // A library with no cover files still gets a pane the same shape,
        // because a layout that changes size with the record is worse than a
        // placeholder.
        Rectangle {
          anchors.fill: parent
          visible: !cover.visible
          color: "transparent"
          border.width: Style.normalBorderWidth
          border.color: root.rule
          radius: Style.cornerRadius

          Text {
            anchors.centerIn: parent
            text: "󰝚"
            color: root.rule
            font.family: root.fontFamily
            font.pixelSize: Math.max(Style.font.displayLarge, Math.round(parent.height * 0.3))
          }
        }
      }
    }

    Rectangle {
      width: Math.max(1, Style.normalBorderWidth)
      height: parent.height
      color: root.rule
    }

    TrackList {
      id: queueList
      width: parent.width - artPane.width - Math.max(1, Style.normalBorderWidth)
      height: parent.height
      leftPadding: Style.space(10)

      rows: root.rows
      playingIndex: root.playingIndex
      focused: root.active
      loading: root.service ? root.service.queueLoading : false
      emptyText: root.service && root.service.connected
        ? "The queue is empty.\nAdd something from Directories, Artists or Search."
        : "Not connected"
      fontFamily: root.fontFamily
      fontSize: root.fontSize
      foreground: root.foreground
      accent: root.accent

      columns: [
        { title: "Artist", field: "artist", weight: 20 },
        { title: "Title", kind: "title", weight: 35 },
        { title: "Album", field: "album", weight: 30 },
        { title: "Len", kind: "duration", weight: 8, align: "right" }
      ]

      onActivated: root.activate()
      onCursorMoved: root.pendingJump = false
    }
  }
}
