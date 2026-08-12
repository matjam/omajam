pragma ComponentBehavior: Bound

import QtQuick
import qs.Commons
import qs.Ui

// Search across every tag, which is MPD's own `search any`.
//
// The query is re-run as the term is typed rather than on Enter, because the
// answer takes a few milliseconds and waiting for a keypress to ask for
// something already known is the slower way round. What makes that affordable
// is the channel: the bridge runs the newest term and drops the ones typed
// before it, so eight keystrokes cost one query rather than eight.
Item {
  id: root

  property var service: null
  property bool active: false

  property string fontFamily: Style.font.family
  property int fontSize: Style.font.bodySmall
  property color foreground: Color.popups.text
  property color accent: Color.accent

  readonly property color dim: Qt.darker(foreground, 1.4)

  readonly property var list: resultList
  readonly property bool inputFocused: field.activeFocus
  readonly property int limit: 1000

  property var results: []
  property bool loading: false
  property bool truncated: false
  property string term: ""

  function focusInput() { field.forceActiveFocus() }
  function blurInput() { field.focus = false }

  // Search for something without typing it, for a caller that already knows
  // what it is looking for. Setting the field rather than the term keeps the
  // two from disagreeing about what is being searched for.
  function setTerm(text) {
    field.text = String(text || "")
    root.term = field.text
  }

  onActiveChanged: if (active && term === "") Qt.callLater(focusInput)

  // ------------------------------------------------------------ searching

  Timer {
    id: debounce
    interval: 180
    repeat: false
    onTriggered: root.runSearch()
  }

  function runSearch() {
    if (!service) return
    var text = term.trim()
    if (text === "") {
      results = []
      loading = false
      truncated = false
      return
    }
    loading = true
    service.request("search", { term: text, channel: "search", limit: limit },
                    function(rows, error, event) {
      root.loading = false
      root.results = rows
      root.truncated = event && event.truncated === true
      if (error !== "") root.results = []
    })
  }

  onTermChanged: {
    results = []
    debounce.restart()
  }

  // ------------------------------------------------------------- actions

  function activate() {
    var row = resultList.currentRow
    if (!service || !row || !row.file) return
    service.addAndPlay(String(row.file))
  }

  function addSelected(andPlay) {
    if (!service) return
    var rows = resultList.targetRows()
    for (var i = 0; i < rows.length; i++) {
      if (!rows[i].file) continue
      if (i === 0 && andPlay) service.addAndPlay(String(rows[i].file))
      else service.addUri(String(rows[i].file))
    }
    resultList.clearMarks()
  }

  function addAll() {
    if (!service) return
    for (var i = 0; i < results.length; i++) {
      if (results[i].file) service.addUri(String(results[i].file))
    }
  }

  // --------------------------------------------------------------- layout

  Column {
    anchors.fill: parent
    spacing: Style.space(8)

    Row {
      width: parent.width
      spacing: Style.space(8)

      Text {
        anchors.verticalCenter: parent.verticalCenter
        text: "󰍉"
        color: root.inputFocused ? root.accent : root.dim
        font.family: root.fontFamily
        font.pixelSize: root.fontSize
      }

      TextField {
        id: field
        width: parent.width - Style.space(28)
        foreground: root.foreground
        placeholderText: "Search every tag — artist, album, title, filename"
        onTextChanged: root.term = text
        // Enter hands the keyboard to the results, which is where the next
        // thing anyone does is.
        onAccepted: {
          focus = false
          resultList.moveTo(0)
        }
      }
    }

    Text {
      width: parent.width
      text: {
        if (root.term.trim() === "") return "Type to search."
        if (root.loading) return "Searching…"
        if (root.results.length === 0) return "Nothing matched “" + root.term.trim() + "”."
        var line = root.results.length + (root.truncated ? "+ matches" : " matches")
        return line + "   ·   enter plays  ·  a adds  ·  A adds all"
      }
      color: root.dim
      font.family: root.fontFamily
      font.pixelSize: Style.font.caption
      elide: Text.ElideRight
    }

    TrackList {
      id: resultList
      width: parent.width
      height: parent.height - y
      rows: root.results
      loading: root.loading
      focused: root.active && !root.inputFocused
      emptyText: ""
      fontFamily: root.fontFamily
      fontSize: root.fontSize
      foreground: root.foreground
      accent: root.accent

      columns: [
        { title: "Artist", field: "artist", weight: 20 },
        { title: "Title", kind: "title", weight: 32 },
        { title: "Album", field: "album", weight: 28 },
        { title: "Len", kind: "duration", weight: 8, align: "right" }
      ]

      onActivated: root.activate()
    }
  }
}
