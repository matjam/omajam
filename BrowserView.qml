pragma ComponentBehavior: Bound

import QtQuick
import qs.Commons

// The library, walked one column at a time.
//
// Six of the client's tabs are this component with a different `mode`, because
// they are the same thing: a list of names, and behind each name a narrower
// list, until what is left is songs. Artists narrow to albums narrow to tracks;
// directories narrow to directories; playlists narrow to their contents. Only
// the queries differ, and those are three lines apiece in `levelQuery` below.
//
// Three columns are on screen: where you came from, where you are, and what is
// behind the row under the cursor. The third is not decoration -- it is the
// query the next keypress would run, run early, so `l` is instant rather than a
// spinner. It is also what makes the browser navigable without descending at
// all: an album's track list is visible from the album list.
Item {
  id: root

  property var service: null
  // directories | artist | albumartist | album | genre | playlists
  property string mode: "directories"
  property bool active: false

  property string fontFamily: Style.font.family
  property int fontSize: Style.font.bodySmall
  property color foreground: Color.popups.text
  property color accent: Color.accent

  // The tint PanelSeparator uses, so the rules between columns match every
  // other divider in the shell.
  readonly property color rule: Qt.rgba(foreground.r, foreground.g, foreground.b, 0.12)

  // Each level: { kind, args, filter, path, rows, index, loading, title }.
  // The last one is the one being driven; the one before it is context.
  property var levels: []
  // Levels are replaced, not mutated, so object identity cannot say whether an
  // answer still belongs to what is on screen. A token can.
  property int nextToken: 1
  property var previewRows: []
  property bool previewLoading: false

  // When the cursor is on a song there is no list behind it, so the third
  // column shows the song itself instead: its cover, and every tag the server
  // holds. Both are fetched on their own channels, so walking a track listing
  // costs one of each at the pace of the cursor rather than one per row.
  property var previewSong: null
  property string previewArt: ""
  readonly property bool showingSong: previewSong !== null

  readonly property var currentLevel: levels.length > 0 ? levels[levels.length - 1] : null
  readonly property var parentLevel: levels.length > 1 ? levels[levels.length - 2] : null
  readonly property bool hasParent: !!parentLevel

  // What the client's key handler drives.
  readonly property var list: mainList

  // ------------------------------------------------------------ the model
  //
  // Which tags this mode narrows through, in order. Directories and playlists
  // have none: they narrow through paths and names instead.
  function tagChain() {
    if (mode === "artist") return ["artist", "album"]
    if (mode === "albumartist") return ["albumartist", "album"]
    if (mode === "album") return ["album"]
    if (mode === "genre") return ["genre", "album"]
    return []
  }

  function newLevel(spec) {
    spec.token = nextToken++
    spec.rows = spec.rows || []
    spec.index = spec.index || 0
    spec.loading = spec.loading === true
    return spec
  }

  function rootLevel() {
    if (mode === "directories")
      return newLevel({ kind: "lsinfo", args: { path: "" }, filter: [], path: "", title: "/" })
    if (mode === "playlists")
      return newLevel({ kind: "listplaylists", args: ({}), filter: [], path: "", title: "Playlists" })
    var tags = tagChain()
    return newLevel({ kind: "list", args: { tag: tags[0] }, filter: [], path: "", title: tags[0] })
  }

  // What kind of level sits behind a row, or "" when the row is a song and
  // nothing does. Pure: it allocates nothing and answers from the row alone,
  // which is what lets a binding ask it. `childLevel` below is the same
  // question answered with a level attached, and that one costs a token.
  function childKindOf(level, row) {
    if (!level || !row) return ""
    var type = String(row.type || "")
    if (type === "directory") return "lsinfo"
    if (type === "playlist") return "playlist"
    if (type !== "value") return ""
    var tags = tagChain()
    var depth = level.filter.length
    if (depth >= tags.length) return ""
    return depth + 1 < tags.length ? "list" : "find"
  }

  // The level behind a row, or null when the row is a song and there is nothing
  // behind it. This is the whole navigation model; everything else is display.
  function childLevel(level, row) {
    if (!level || !row) return null
    var type = String(row.type || "")

    if (type === "directory")
      return newLevel({ kind: "lsinfo", args: { path: row.directory }, filter: [],
                        path: row.directory, title: baseName(row.directory) })

    if (type === "playlist")
      return newLevel({ kind: "playlist", args: { name: row.playlist }, filter: [],
                        path: row.playlist, title: baseName(row.playlist) })

    if (type !== "value") return null  // a song: the end of the line

    var tags = tagChain()
    var depth = level.filter.length
    if (depth >= tags.length) return null
    var filter = level.filter.concat([[tags[depth], String(row.value || "")]])
    if (depth + 1 < tags.length) {
      return newLevel({ kind: "list", args: { tag: tags[depth + 1], filter: filter },
                        filter: filter, path: "", title: String(row.value || "") })
    }
    return newLevel({ kind: "find", args: { filter: filter, sort: "track" },
                      filter: filter, path: "", title: String(row.value || "") })
  }

  function baseName(path) {
    var name = String(path || "")
    var slash = name.lastIndexOf("/")
    return slash === -1 ? name : name.substring(slash + 1)
  }

  // Songs get a track number and a duration; names get the whole width.
  function columnsForKind(kind) {
    if (kind === "") return []
    if (kind === "find" || kind === "playlist")
      return [{ kind: "track", weight: 1, align: "right" },
              { kind: "title", weight: 9 },
              { kind: "duration", weight: 2, align: "right" }]
    return [{ kind: "entry", weight: 1 }]
  }

  function columnsFor(level) {
    return columnsForKind(level ? String(level.kind || "") : "")
  }

  // ------------------------------------------------------------- loading

  function load(index) {
    if (!service || index < 0 || index >= levels.length) return
    var level = levels[index]
    var token = level.token
    var args = ({})
    for (var key in level.args) args[key] = level.args[key]
    args.channel = "browse-" + mode + "-" + index
    setLevel(index, { loading: true })
    service.request(level.kind, args, function(rows, error) {
      // A level popped, or replaced, while its answer was in flight has nothing
      // to do with what is on screen now.
      if (index >= root.levels.length || root.levels[index].token !== token) return
      root.setLevel(index, { rows: rows, loading: false, error: error })
      if (index === root.levels.length - 1) root.refreshPreview()
    })
  }

  // Levels are replaced rather than mutated: a bound list reads `levels`, and
  // QML compares by reference.
  function setLevel(index, changes) {
    var next = levels.slice()
    var level = ({})
    for (var key in next[index]) level[key] = next[index][key]
    for (var change in changes) level[change] = changes[change]
    next[index] = level
    levels = next
  }

  function reset() {
    levels = [rootLevel()]
    previewRows = []
    load(0)
  }

  function reload() {
    // Everything on screen, from where it is: a database update should not
    // throw away the path the user walked to get here.
    for (var i = 0; i < levels.length; i++) load(i)
  }

  // Nothing is fetched for a tab nobody has opened. All eight panes exist from
  // the moment the panel does -- an empty one costs nothing -- but a shell that
  // only ever shows the queue never asks the server for the artist list.
  onActiveChanged: if (active) ensureLoaded()

  function ensureLoaded() {
    if (!active || !service || !service.connected) return
    if (levels.length === 0) reset()
  }

  Connections {
    target: root.service

    function onConnectedChanged() {
      if (root.service.connected) root.ensureLoaded()
      else root.levels = []
    }

    // A scan has finished, so every row on screen is describing the library as
    // it was before it. Refetch in place rather than resetting: the path walked
    // to get here is usually still there, and being thrown back to the root of
    // the artist list because a file was added elsewhere would be its own bug.
    function onDatabaseVersionChanged() {
      if (root.levels.length > 0) root.reload()
    }
  }

  // ------------------------------------------------------------- preview

  Timer {
    id: previewDelay
    interval: 120
    repeat: false
    onTriggered: root.fetchPreview()
  }

  // Held down, `j` walks a hundred rows in a second and every one of them would
  // otherwise be a query. The bridge would drop the stale ones, but the cheapest
  // query is the one never sent.
  function refreshPreview() {
    previewRows = []
    previewDelay.restart()
  }

  function fetchPreview() {
    var level = currentLevel
    if (!service || !level) return
    var row = (level.rows && level.index < level.rows.length) ? level.rows[level.index] : null
    var child = childLevel(level, row)
    if (!child) {
      previewRows = []
      previewLoading = false
      fetchSong(row)
      return
    }
    previewSong = null
    previewArt = ""
    var args = ({})
    for (var key in child.args) args[key] = child.args[key]
    args.channel = "preview-" + mode
    args.limit = 500
    previewLoading = true
    service.request(child.kind, args, function(rows) {
      root.previewLoading = false
      root.previewRows = rows
    })
  }

  // The song under the cursor, in full. The row already in hand carries only
  // the fields the list needed; this asks for the rest, and for a cover.
  function fetchSong(row) {
    if (!row || String(row.type || "") !== "file" || !row.file) {
      previewSong = null
      previewArt = ""
      return
    }
    // Show what is already known while the rest arrives, so the pane fills
    // immediately rather than blinking.
    previewSong = row
    previewArt = ""
    var uri = String(row.file)

    service.request("songinfo", { file: uri, channel: "songinfo-" + mode },
                    function(rows) {
      if (rows.length > 0 && root.previewSong && String(root.previewSong.file || "") === uri)
        root.previewSong = rows[0]
    })

    service.request("art", { uri: uri, album: String(row.album || ""),
                             albumartist: String(row.albumartist || ""),
                             channel: "songart-" + mode }, function(rows) {
      if (rows.length > 0 && root.previewSong && String(root.previewSong.file || "") === uri)
        root.previewArt = String(rows[0].path || "")
    })
  }

  // ------------------------------------------------------------ movement

  function descend() {
    var level = currentLevel
    if (!level || !level.rows || level.rows.length === 0) return
    var row = level.rows[level.index]
    var child = childLevel(level, row)
    if (!child) return
    // The preview already holds the answer whenever the cursor sat still long
    // enough for it to arrive, which is nearly always, so `l` lands on a list
    // rather than on the word "Loading".
    child.rows = previewLoading ? [] : previewRows
    child.loading = previewLoading
    levels = levels.concat([child])
    if (child.rows.length === 0) load(levels.length - 1)
    else refreshPreview()
  }

  // A click in the column on the right steps into it and lands on that row --
  // the same thing `l` does, with the destination chosen by the pointer. The
  // preview is already holding the rows, so this costs no query.
  function descendTo(index) {
    var level = currentLevel
    if (!level || !level.rows || level.rows.length === 0) return
    if (!childKindOf(level, level.rows[level.index])) return
    descend()
    if (levels.length === 0) return
    setLevel(levels.length - 1, { index: Math.max(0, index) })
    Qt.callLater(restoreCursor)
    refreshPreview()
  }

  // And a click in the column on the left steps back out to that row.
  function ascendTo(index) {
    if (levels.length <= 1) return
    levels = levels.slice(0, levels.length - 1)
    setLevel(levels.length - 1, { index: Math.max(0, index) })
    Qt.callLater(restoreCursor)
    refreshPreview()
  }

  function ascend() {
    if (levels.length <= 1) return
    levels = levels.slice(0, levels.length - 1)
    refreshPreview()
  }

  // ------------------------------------------------------------- actions

  function rowUri(row) {
    if (!row) return ""
    var type = String(row.type || "")
    if (type === "directory") return String(row.directory || "")
    if (type === "file") return String(row.file || "")
    return ""
  }

  // Add what is under the cursor -- or everything marked, when anything is.
  // A tag value adds as a filter rather than as a list of files: an artist is
  // one `findadd` on the server rather than nine hundred `add` lines from here.
  function addSelected(andPlay) {
    var level = currentLevel
    if (!service || !level) return
    var rows = mainList.targetRows()
    for (var i = 0; i < rows.length; i++) {
      var row = rows[i]
      var type = String(row.type || "")
      var first = i === 0 && andPlay
      if (type === "value") {
        var child = childLevel(level, row)
        if (!child) continue
        if (first) service.addFilterAndPlay(child.filter)
        else service.addFilter(child.filter)
      } else if (type === "playlist") {
        service.loadPlaylist(String(row.playlist || ""))
      } else {
        var uri = rowUri(row)
        if (uri === "") continue
        if (first) service.addAndPlay(uri)
        else service.addUri(uri)
      }
    }
    mainList.clearMarks()
  }

  // Everything in the level being shown, from one command.
  function addAll() {
    var level = currentLevel
    if (!service || !level) return
    if (level.kind === "lsinfo") service.addUri(level.path)
    else if (level.kind === "playlist") service.loadPlaylist(level.path)
    else if (level.filter && level.filter.length > 0) service.addFilter(level.filter)
    // A tag list with no filter behind it is the whole library, which is not
    // something to do because a capital letter was pressed.
  }

  function activate() {
    var level = currentLevel
    if (!level || !level.rows || level.rows.length === 0) return
    var row = level.rows[level.index]
    if (childLevel(level, row)) descend()
    else addSelected(true)
  }

  function deleteSelected() {
    // Only playlists can be deleted from the browser, and only whole ones.
    var level = currentLevel
    if (!service || !level || level.kind !== "listplaylists") return
    var rows = mainList.targetRows()
    for (var i = 0; i < rows.length; i++) {
      if (String(rows[i].type || "") === "playlist")
        service.removePlaylist(String(rows[i].playlist || ""))
    }
    Qt.callLater(function() { root.load(0) })
  }

  // Where the client's header shows what you are looking at.
  readonly property string breadcrumb: {
    var parts = []
    for (var i = 0; i < levels.length; i++) {
      var title = String(levels[i].title || "")
      if (title !== "") parts.push(title)
    }
    return parts.join("  ›  ")
  }


  // --------------------------------------------------------------- layout

  Row {
    anchors.fill: parent
    spacing: 0

    // Where you came from. It keeps its cursor so `h` lands back on the row you
    // descended through rather than at the top of the list.
    Item {
      width: root.hasParent ? Math.round(root.width * 0.22) : 0
      height: parent.height
      visible: width > 0

      TrackList {
        anchors.fill: parent
        anchors.rightMargin: Style.space(8)
        rows: root.parentLevel ? (root.parentLevel.rows || []) : []
        columns: root.columnsFor(root.parentLevel)
        currentIndex: root.parentLevel ? Number(root.parentLevel.index || 0) : 0
        focused: false
        selectOnClick: false
        onRowClicked: function(index) { root.ascendTo(index) }
        showHeader: false
        emptyText: ""
        fontFamily: root.fontFamily
        fontSize: root.fontSize
        foreground: root.foreground
        accent: root.accent
      }
    }

    Rectangle {
      visible: root.hasParent
      width: visible ? Math.max(1, Style.normalBorderWidth) : 0
      height: parent.height
      color: root.rule
    }

    // The list being driven.
    Item {
      width: root.width
        - (root.hasParent ? Math.round(root.width * 0.22) + Math.max(1, Style.normalBorderWidth) : 0)
        - previewPane.width - Math.max(1, Style.normalBorderWidth)
      height: parent.height

      TrackList {
        id: mainList
        anchors.fill: parent
        anchors.leftMargin: root.hasParent ? Style.space(8) : 0
        anchors.rightMargin: Style.space(8)
        rows: root.currentLevel ? (root.currentLevel.rows || []) : []
        columns: root.columnsFor(root.currentLevel)
        loading: root.currentLevel ? root.currentLevel.loading === true : false
        focused: root.active
        showHeader: false
        emptyText: {
          if (!root.service || !root.service.connected) return "Not connected"
          if (root.currentLevel && root.currentLevel.error) return root.currentLevel.error
          return "Nothing here"
        }
        fontFamily: root.fontFamily
        fontSize: root.fontSize
        foreground: root.foreground
        accent: root.accent

        onCursorMoved: function(index) {
          root.setLevel(root.levels.length - 1, { index: index })
          root.refreshPreview()
        }
        onActivated: root.activate()
        onDescended: root.descend()
      }
    }

    Rectangle {
      width: Math.max(1, Style.normalBorderWidth)
      height: parent.height
      color: root.rule
    }

    // What is behind the cursor, fetched before it is asked for.
    Item {
      id: previewPane
      width: Math.round(root.width * (root.hasParent ? 0.40 : 0.50))
      height: parent.height

      SongInfo {
        anchors.fill: parent
        anchors.leftMargin: Style.space(8)
        visible: root.showingSong
        song: root.previewSong || ({})
        artPath: root.previewArt
        loading: root.previewLoading
        fontFamily: root.fontFamily
        fontSize: root.fontSize
        foreground: root.foreground
        accent: root.accent
      }

      TrackList {
        anchors.fill: parent
        anchors.leftMargin: Style.space(8)
        visible: !root.showingSong
        rows: root.previewRows
        // Asked of `childKindOf` rather than of `childLevel`: building a level
        // stamps it with a token, and a binding that writes a property it also
        // reads is a binding loop.
        columns: {
          var level = root.currentLevel
          if (!level || !level.rows || level.rows.length === 0) return []
          return root.columnsForKind(root.childKindOf(level, level.rows[level.index]))
        }
        currentIndex: -1
        focused: false
        selectOnClick: false
        onRowClicked: function(index) { root.descendTo(index) }
        // A double-click steps in and plays, since the first click has already
        // put the cursor on the row.
        onActivated: root.activate()
        showHeader: false
        loading: root.previewLoading
        emptyText: ""
        fontFamily: root.fontFamily
        fontSize: root.fontSize
        foreground: root.foreground
        accent: root.accent
      }
    }
  }

  Component.onDestruction: previewDelay.stop()

  onModeChanged: if (service && service.connected) reset()

  // The cursor is the list's, not the level's -- binding `currentIndex` would
  // be overwritten the first time the list moved it. The level only remembers
  // where the cursor was so that walking back out lands on the row walked in
  // through, and this puts it back after every push and pop.
  onLevelsChanged: Qt.callLater(restoreCursor)

  function restoreCursor() {
    var level = currentLevel
    if (!level) return
    var rows = level.rows || []
    mainList.currentIndex = Math.max(0, Math.min(Number(level.index) || 0, rows.length - 1))
  }
}
