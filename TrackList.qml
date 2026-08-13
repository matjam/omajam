// Delegates reach `root` and their own row data from inside a Component, which
// is a separate scope; the pragma plus `required property` is what makes both
// resolve at compile time rather than late and by name.
pragma ComponentBehavior: Bound

import QtQuick
import qs.Commons

// The list every pane in the client is made of.
//
// One column or four, it is the same thing: rows of text, a cursor that moves
// on j/k, a highlight on the row the server is playing, and a scrollbar drawn
// the way a terminal draws one. Panes differ in what they put in the rows and
// what Enter means, not in how the rows behave, so all of that lives here.
//
// Rows are plain objects straight from the bridge -- an MPD song, a directory
// entry, a tag value -- and `columns` says which of their fields to show and
// how. Nothing is copied into a ListModel: a ten thousand song queue is a
// ten thousand element array either way, and copying it would double that for
// no gain.
Item {
  id: root

  property var rows: []
  // [{ field, title, kind, weight, align }] -- kind picks the formatter below,
  // weight is a share of the width, and a column with no title hides the header
  // row for everyone.
  property var columns: []
  property bool showHeader: true

  property int currentIndex: 0
  // Rows the user has marked with space. An object rather than an array
  // because membership is the only question ever asked of it.
  property var marked: ({})
  property int markedCount: 0

  // The index the server is playing, if this list is showing the queue.
  property int playingIndex: -1

  // A list that does not have the keyboard draws a dimmer cursor -- the browser
  // shows three of these side by side and only one of them is being driven.
  property bool focused: true
  property bool clickable: true
  // Whether a click moves this list's own cursor. The browser's side columns
  // take clicks but do not move: a click there means step into that column, or
  // back out to it, and the cursor that matters afterwards belongs to whichever
  // list the step landed on.
  property bool selectOnClick: true
  property bool loading: false
  property string emptyText: "Empty"
  // Every one of these is a theme decision rather than this plugin's. The font
  // is whatever the shell was told to use, the cursor row is drawn the way the
  // omarchy menu draws its own, and the rules are the tint PanelSeparator uses.
  property string fontFamily: Style.font.family
  property int fontSize: Style.font.bodySmall
  property int leftPadding: Style.space(6)
  property int rightPadding: Style.space(6)
  // Rows per notch of a mouse wheel. Flickable's own step is sized for a page
  // of prose; on rows nineteen pixels tall that is a crawl, and a queue is
  // something you scan rather than read. Three notches clears a screen.
  property int wheelRows: 10
  // How much faster than one-to-one a pixel-reporting device scrolls.
  property real wheelPixelFactor: 3

  property color foreground: Color.popups.text
  property color accent: Color.accent
  property color selectedBackground: Color.menu.selectedBackground
  property color selectedText: Color.menu.selectedText
  readonly property color dim: Qt.darker(foreground, 1.4)
  readonly property color rule: Qt.rgba(foreground.r, foreground.g, foreground.b, 0.12)

  readonly property int count: rows ? rows.length : 0
  readonly property var currentRow: (count > 0 && currentIndex >= 0 && currentIndex < count)
    ? rows[currentIndex] : null
  readonly property int rowHeight: Math.max(Style.space(18), root.fontSize + Style.space(8))
  readonly property int columnGap: Style.space(8)

  signal activated(int index)
  signal descended(int index)   // right-click -- into a directory, an album
  // Raised before anything moves, so a caller can take the click and do
  // something other than select with it.
  signal rowClicked(int index)
  // Any move of the cursor, whether a key did it or a caller assigned it. The
  // browser stores it on the level it belongs to and fetches a fresh preview,
  // and both of those are wanted for a restored cursor as much as for a typed
  // one.
  signal cursorMoved(int index)

  onCurrentIndexChanged: {
    cursorMoved(currentIndex)
    // The cursor of a list nobody is driving -- the browser's left-hand column,
    // showing where you came from -- is moved by assignment rather than by
    // moveTo, and would otherwise be highlighted somewhere off screen.
    Qt.callLater(ensureVisible)
  }

  function ensureVisible() {
    if (count > 0) view.positionViewAtIndex(clamp(currentIndex), ListView.Contain)
  }

  // ------------------------------------------------------------- movement

  function clamp(index) {
    if (count === 0) return 0
    return Math.max(0, Math.min(count - 1, index))
  }

  function moveTo(index) {
    currentIndex = clamp(index)
    view.positionViewAtIndex(currentIndex, ListView.Contain)
  }

  function move(delta) { moveTo(currentIndex + delta) }
  // `toTop`/`toBottom` rather than `top`/`bottom`: those are Item's own
  // anchor lines, and shadowing them breaks anchoring for anyone using this.
  function toTop() { moveTo(0) }
  function toBottom() { moveTo(count - 1) }

  // A page is what is on screen, less one row of overlap so the eye keeps its
  // place -- the same thing every pager does.
  function pageSize() {
    return Math.max(1, Math.floor(view.height / rowHeight) - 1)
  }

  function pageUp() { moveTo(currentIndex - pageSize()) }
  function pageDown() { moveTo(currentIndex + pageSize()) }
  function halfPageUp() { moveTo(currentIndex - Math.max(1, Math.floor(pageSize() / 2))) }
  function halfPageDown() { moveTo(currentIndex + Math.max(1, Math.floor(pageSize() / 2))) }

  // Scroll the view without moving the cursor -- the wheel looks around, it does
  // not select. Any flick still in flight is cancelled first, or the inertia
  // fights the notch.
  function scrollByRows(rows) {
    var span = Math.max(0, view.contentHeight - view.height)
    if (span <= 0) return
    view.cancelFlick()
    view.contentY = Math.max(0, Math.min(span, view.contentY - rows * rowHeight))
  }

  function centerCursor() { view.positionViewAtIndex(currentIndex, ListView.Center) }
  function cursorToTop() { view.positionViewAtIndex(currentIndex, ListView.Beginning) }
  function cursorToBottom() { view.positionViewAtIndex(currentIndex, ListView.End) }

  // Jump to the next row whose text starts with, or contains, this text. The
  // browser's `/` search and rmpc's n/N both land here.
  function findNext(needle, from, direction) {
    var text = String(needle || "").toLowerCase()
    if (text === "" || count === 0) return -1
    for (var step = 1; step <= count; step++) {
      var index = ((from + step * direction) % count + count) % count
      if (rowSearchText(rows[index]).toLowerCase().indexOf(text) !== -1) return index
    }
    return -1
  }

  // ------------------------------------------------------------- marking

  function isMarked(index) { return marked[index] === true }

  function toggleMark(index) {
    var next = ({})
    for (var key in marked) next[key] = marked[key]
    if (next[index]) delete next[index]
    else next[index] = true
    marked = next
    markedCount = Object.keys(next).length
  }

  function clearMarks() {
    marked = ({})
    markedCount = 0
  }

  function invertMarks() {
    var next = ({})
    for (var i = 0; i < count; i++) {
      if (!marked[i]) next[i] = true
    }
    marked = next
    markedCount = Object.keys(next).length
  }

  // Marked rows if there are any, otherwise the row under the cursor: `a` and
  // `d` should do something whether or not anything was marked.
  function targetRows() {
    if (markedCount === 0) return currentRow ? [currentRow] : []
    var out = []
    for (var i = 0; i < count; i++) {
      if (marked[i]) out.push(rows[i])
    }
    return out
  }

  // Marks are indexes, and every index means something else once the rows
  // change underneath them.
  //
  // The cursor is deliberately not clamped here. A caller may bind it -- the
  // browser's parent column binds it to the level it is showing -- and writing
  // to a bound property from inside destroys that binding for good, which left
  // the column you came from highlighting its first row forever. Out of range
  // is harmless: `currentRow` is null, no delegate matches, and the next move
  // clamps it back.
  onRowsChanged: {
    clearMarks()
    Qt.callLater(ensureVisible)
  }

  // ------------------------------------------------------------ formatting

  function formatDuration(seconds) {
    var total = Math.floor(Number(seconds) || 0)
    if (!(total > 0)) return "-"
    var mins = Math.floor(total / 60)
    var secs = total % 60
    var pad = secs < 10 ? "0" + secs : String(secs)
    if (mins < 60) return mins + ":" + pad
    var hours = Math.floor(mins / 60)
    var rest = mins % 60
    return hours + ":" + (rest < 10 ? "0" + rest : String(rest)) + ":" + pad
  }

  function baseName(path) {
    var name = String(path || "")
    var slash = name.lastIndexOf("/")
    return slash === -1 ? name : name.substring(slash + 1)
  }

  function stripExtension(name) {
    var dot = name.lastIndexOf(".")
    return dot > 0 ? name.substring(0, dot) : name
  }

  // The text of one cell. `kind` is what makes a column of durations right
  // aligned numbers and a column of file paths a readable name.
  function cellText(row, column, index) {
    if (!row || !column) return ""
    var kind = String(column.kind || "text")
    if (kind === "index") return String(index + 1)
    if (kind === "duration") return formatDuration(row.duration || row.time)
    if (kind === "title") {
      var title = String(row.title || "")
      return title !== "" ? title : stripExtension(baseName(row.file))
    }
    if (kind === "entry") {
      // A directory, a stored playlist or a song, whichever this row is.
      var type = String(row.type || "")
      if (type === "directory") return baseName(row.directory)
      if (type === "playlist") return baseName(row.playlist)
      if (type === "value") return String(row.value || "")
      var name = String(row.title || "")
      return name !== "" ? name : stripExtension(baseName(row.file))
    }
    if (kind === "track") {
      // "4/12" is a legal track tag and only the first half is the number.
      var track = String(row.track || "").split("/")[0]
      return track
    }
    var value = row[String(column.field || "")]
    return value === undefined || value === null ? "" : String(value)
  }

  // What `/` matches against: everything the row is showing, so a search for an
  // album name finds it in the column it is displayed in.
  function rowSearchText(row) {
    if (!row) return ""
    var parts = []
    for (var i = 0; i < columns.length; i++) parts.push(cellText(row, columns[i], 0))
    return parts.join(" ")
  }

  function glyphFor(row) {
    if (!row) return ""
    var type = String(row.type || "")
    if (type === "directory") return "󰉋 "
    if (type === "playlist") return "󰲸 "
    return ""
  }

  readonly property bool headerVisible: showHeader && columns.length > 0
    && String(columns[0].title || "") !== ""

  // --------------------------------------------------------------- header

  Item {
    id: header
    visible: root.headerVisible
    height: visible ? root.rowHeight : 0
    anchors { top: parent.top; left: parent.left; right: parent.right }

    Row {
      anchors.fill: parent
      anchors.leftMargin: root.leftPadding
      anchors.rightMargin: root.rightPadding + scrollbar.width
      spacing: root.columnGap

      Repeater {
        model: root.columns

        delegate: Text {
          required property var modelData
          required property int index

          width: root.columnWidth(index, header.width - root.leftPadding - root.rightPadding - scrollbar.width)
          height: header.height
          verticalAlignment: Text.AlignVCenter
          horizontalAlignment: String(modelData.align || "left") === "right"
            ? Text.AlignRight : Text.AlignLeft
          text: String(modelData.title || "")
          color: root.dim
          font.bold: true
          font.family: root.fontFamily
          font.pixelSize: root.fontSize
          elide: Text.ElideRight
        }
      }
    }

    // The rule under the column titles. Same tint as PanelSeparator, which is
    // what every other omarchy panel draws a divider with.
    Rectangle {
      anchors { left: parent.left; right: parent.right; bottom: parent.bottom }
      height: Math.max(1, Style.normalBorderWidth)
      color: root.rule
    }
  }

  // Column widths are shares of what is left, so a table stays a table when the
  // panel is resized and a column of durations never takes a quarter of it.
  function columnWidth(index, available) {
    if (!columns || index < 0 || index >= columns.length) return 0
    var total = 0
    for (var i = 0; i < columns.length; i++) total += Number(columns[i].weight || 1)
    if (total <= 0) return 0
    // The gaps come out of the width before it is shared, or the columns would
    // add up to more than the row and the last one would fall off the end.
    var usable = Math.max(0, available - columnGap * Math.max(0, columns.length - 1))
    return Math.floor(usable * Number(columns[index].weight || 1) / total)
  }

  // ---------------------------------------------------------------- rows

  ListView {
    id: view
    anchors {
      top: header.visible ? header.bottom : parent.top
      left: parent.left
      right: parent.right
      bottom: parent.bottom
    }
    clip: true
    model: root.rows
    // The cursor is root.currentIndex; letting the view keep a second one of
    // its own only creates a pair that can disagree.
    currentIndex: -1
    highlightFollowsCurrentItem: false
    boundsBehavior: Flickable.StopAtBounds
    reuseItems: true
    cacheBuffer: root.rowHeight * 20

    // The wheel, from whatever kind of device claims to have one.
    //
    // Two spellings arrive and a device may send either or both. A classic
    // wheel sends angleDelta in eighths of a degree, 120 to a notch. A
    // high-resolution wheel or a touchpad sends a stream of small pixelDeltas,
    // and may send fractions of 120 alongside them. Both are handled, angle
    // first, because when both are present the angle is the one with detents
    // behind it.
    //
    // No device filter: which category a wheel lands in is the compositor's
    // opinion, and a filter that guesses wrong silently does nothing at all.
    WheelHandler {
      onWheel: function(event) {
        if (event.angleDelta.y !== 0) {
          root.scrollByRows(root.wheelRows * event.angleDelta.y / 120)
          return
        }
        if (event.pixelDelta.y !== 0) {
          // Pixels are already the unit the view scrolls in; the multiplier is
          // only there so a device that reports them keeps pace with one that
          // reports notches.
          root.scrollByRows(root.wheelPixelFactor * event.pixelDelta.y / root.rowHeight)
        }
      }
    }

    delegate: Item {
      id: rowItem
      required property var modelData
      required property int index

      width: view.width
      height: root.rowHeight

      readonly property bool isCursor: index === root.currentIndex
      readonly property bool isPlaying: index === root.playingIndex
      readonly property bool isMarked: root.marked[index] === true

      // The cursor row, drawn the way the omarchy menu draws its own: the
      // theme's selected-row fill, its selected-row text colour, and the
      // shell's corner radius. A list nobody is driving -- the browser's side
      // columns -- gets the same fill at half strength, because three lists
      // side by side must not look like three cursors.
      Rectangle {
        anchors.fill: parent
        visible: rowItem.isCursor || rowItem.isMarked
        radius: Style.cornerRadius
        color: {
          if (rowItem.isCursor && root.focused) return root.selectedBackground
          if (rowItem.isCursor) return Qt.rgba(root.selectedBackground.r, root.selectedBackground.g,
                                               root.selectedBackground.b, root.selectedBackground.a * 0.5)
          return Style.selectionFill
        }
      }

      // The marker column of a marked row, in the gutter, so a marked row that
      // is also under the cursor still says so.
      Rectangle {
        visible: rowItem.isMarked
        width: Math.max(2, Style.space(2))
        height: parent.height
        radius: Style.cornerRadius
        color: root.accent
      }

      Row {
        anchors.fill: parent
        anchors.leftMargin: root.leftPadding
        anchors.rightMargin: root.rightPadding + scrollbar.width
        spacing: root.columnGap

        Repeater {
          model: root.columns

          delegate: Text {
            required property var modelData
            required property int index

            width: root.columnWidth(index, rowItem.width - root.leftPadding - root.rightPadding - scrollbar.width)
            height: rowItem.height
            verticalAlignment: Text.AlignVCenter
            horizontalAlignment: String(modelData.align || "left") === "right"
              ? Text.AlignRight : Text.AlignLeft
            text: (index === 0 ? root.glyphFor(rowItem.modelData) : "")
              + root.cellText(rowItem.modelData, modelData, rowItem.index)
            color: {
              if (rowItem.isCursor) return root.selectedText
              if (rowItem.isPlaying) return root.accent
              return root.foreground
            }
            font.family: root.fontFamily
            font.pixelSize: root.fontSize
            font.bold: rowItem.isPlaying || rowItem.isCursor
            elide: Text.ElideRight
          }
        }
      }

      MouseArea {
        anchors.fill: parent
        enabled: root.clickable
        acceptedButtons: Qt.LeftButton | Qt.RightButton
        onClicked: function(mouse) {
          root.rowClicked(rowItem.index)
          if (root.selectOnClick) root.moveTo(rowItem.index)
          if (mouse.button === Qt.RightButton) root.descended(rowItem.index)
        }
        onDoubleClicked: root.activated(rowItem.index)
      }
    }

    // Nothing to show is three different situations and they read differently.
    Text {
      anchors.centerIn: parent
      width: parent.width - Style.space(24)
      horizontalAlignment: Text.AlignHCenter
      visible: root.count === 0
      text: root.loading ? "Loading…" : root.emptyText
      color: root.dim
      font.family: root.fontFamily
      font.pixelSize: root.fontSize
      wrapMode: Text.WordWrap
    }
  }

  // ------------------------------------------------------------ scrollbar
  //
  // Drawn thin like a terminal's, but a real one: the thumb can be grabbed and
  // dragged, and a click on the track jumps there. Four pixels is too little to
  // aim at, so the hit area reaches further left than the paint does.

  Item {
    id: scrollbar

    readonly property real span: Math.max(0, view.contentHeight - view.height)
    readonly property real thumbHeight: Math.max(Style.space(12),
      height * Math.min(1, view.height / Math.max(1, view.contentHeight)))
    readonly property real travel: Math.max(0, height - thumbHeight)

    width: root.count > 0 && scrollbar.span > 0 ? Math.max(3, Style.space(4)) : 0
    visible: width > 0
    anchors { top: view.top; right: parent.right; bottom: view.bottom }

    // `y` is where the top of the thumb wants to be; this is the inverse of the
    // binding that positions it.
    function scrollTo(y) {
      if (travel <= 0 || span <= 0) return
      view.cancelFlick()
      view.contentY = Math.max(0, Math.min(span, span * Math.max(0, Math.min(1, y / travel))))
    }

    Rectangle {
      anchors.fill: parent
      color: root.rule
    }

    Rectangle {
      id: thumb
      width: parent.width
      height: scrollbar.thumbHeight
      y: scrollbar.span <= 0 ? 0
        : Math.round(scrollbar.travel * Math.max(0, Math.min(1, view.contentY / scrollbar.span)))
      color: root.accent
      opacity: {
        if (grip.pressed) return 1.0
        if (grip.containsMouse) return 0.95
        return root.focused ? 0.9 : 0.45
      }
    }

    MouseArea {
      id: grip
      anchors.fill: parent
      // Wider than it looks: a four pixel target is a fair test of anyone's aim.
      anchors.leftMargin: -Style.space(8)
      hoverEnabled: true
      cursorShape: Qt.ArrowCursor
      preventStealing: true

      // Where in the thumb it was grabbed, so it does not jump under the
      // pointer on the first pixel of the drag.
      property real grabOffset: 0

      onPressed: function(mouse) {
        if (mouse.y >= thumb.y && mouse.y <= thumb.y + thumb.height) {
          grabOffset = mouse.y - thumb.y
          return
        }
        // A click on the track goes there rather than paging towards it: on a
        // queue of ten thousand, paging is a long way to click.
        grabOffset = thumb.height / 2
        scrollbar.scrollTo(mouse.y - grabOffset)
      }

      onPositionChanged: function(mouse) {
        if (!pressed) return
        scrollbar.scrollTo(mouse.y - grabOffset)
      }
    }
  }
}
