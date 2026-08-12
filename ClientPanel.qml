pragma ComponentBehavior: Bound

import QtQuick
import qs.Commons
import qs.Ui

// The client: everything MPD can be asked, in one panel.
//
// It is rmpc's screen, in a Wayland popup rather than a terminal: a header that
// says what is playing, a row of tabs, a pane per tab, and a progress bar along
// the bottom. Boxes are drawn with single lines because that is what a TUI has
// to draw them with, and keeping it makes the two look like the same program.
//
// The keyboard is the point. Every key rmpc binds by default is bound here to
// the same thing -- j/k to move, a to add, / to find, z/x/c/v for the server's
// four playback options -- so the muscle memory carries over. The mouse works
// too, but nothing here needs it.
//
// This owns no state about MPD. The service does, and this reads it; the panes
// ask it their own questions. What this owns is which tab is showing, where the
// keyboard is pointed, and what a key means when it arrives.
Item {
  id: root

  property var bar: null
  property var service: null
  property Item anchorItem: null
  property bool open: false

  // The widget's saved settings and the things only the widget can answer.
  // The settings tab shows them; the widget saves them, because writing to
  // shell.json is the shell's job and the widget is what talks to the shell.
  property var widgetSettings: ({})
  property string version: ""
  property int pythonPresent: -1

  signal persistRequested(string key, var value)

  // Everything about how this looks is the shell's decision, not the plugin's.
  // The font is the one the bar was told to use, the colours are the theme's
  // popup and menu tokens, and the boxes are drawn at the shell's own border
  // width and corner radius -- so a theme change moves this panel with it.
  property string fontFamily: bar ? bar.fontFamily : Style.font.family
  readonly property color fg: Color.popups.text
  readonly property color bg: Color.popups.background
  readonly property color accent: Color.accent
  readonly property color dim: Qt.darker(fg, 1.4)
  readonly property color line: Color.popups.border
  readonly property color rule: Qt.rgba(fg.r, fg.g, fg.b, 0.12)

  readonly property bool connected: !!service && service.connected
  readonly property bool hasSong: connected && service.hasSong

  // `open` is bound by whoever owns this panel, so closing asks rather than
  // assigns: writing to it here would break that binding and the panel could
  // never be opened again.
  signal closeRequested()

  function close() { root.closeRequested() }

  // KeyboardPanel closes itself through its owner, and its `open` is bound to
  // ours -- so the owner has to be something that can set ours rather than the
  // panel, or the first close would overwrite the binding.
  QtObject {
    id: ownerProxy
    property bool popoutSwitchClosing: false
    function close() { root.close() }
  }

  // ============================================================ tab model

  readonly property var tabs: [
    { key: "queue", label: "Queue" },
    { key: "directories", label: "Directories" },
    { key: "artists", label: "Artists" },
    { key: "albumartists", label: "Album Artists" },
    { key: "albums", label: "Albums" },
    { key: "genre", label: "Genre" },
    { key: "playlists", label: "Playlists" },
    { key: "search", label: "Search" },
    // Last, and reachable with 9, because it is the one tab that is about this
    // plugin rather than about the music.
    { key: "settings", label: "󰒓 Settings" }
  ]

  property int tabIndex: 0
  readonly property string tab: tabs[tabIndex].key

  function switchTab(delta) {
    tabIndex = ((tabIndex + delta) % tabs.length + tabs.length) % tabs.length
  }

  function goToTab(index) {
    if (index >= 0 && index < tabs.length) tabIndex = index
  }

  function goToTabKey(key) {
    for (var i = 0; i < tabs.length; i++) {
      if (tabs[i].key === key) {
        tabIndex = i
        return
      }
    }
  }

  // What the cog in the bar opens.
  function openSettings() { goToTabKey("settings") }

  // Open on Search with the box already filled, for a keybind or a script that
  // knows what it is looking for.
  function searchFor(term) {
    goToTabKey("search")
    var view = pane()
    if (view && typeof view.setTerm === "function") view.setTerm(String(term || ""))
  }

  // The pane showing, as an object. Everything the key handler does to a pane
  // goes through here, and every pane answers the same few names: `list`, and
  // whichever of activate/addSelected/deleteSelected it can honour.
  function pane() {
    if (tab === "queue") return queueView
    if (tab === "search") return searchView
    if (tab === "directories") return directoriesView
    if (tab === "artists") return artistsView
    if (tab === "albumartists") return albumArtistsView
    if (tab === "albums") return albumsView
    if (tab === "genre") return genreView
    if (tab === "playlists") return playlistsView
    if (tab === "settings") return settingsView
    return null
  }

  function paneList() {
    var view = pane()
    return view && view.list ? view.list : null
  }

  function callPane(name, arg) {
    var view = pane()
    if (view && typeof view[name] === "function") {
      if (arg === undefined) view[name]()
      else view[name](arg)
      return true
    }
    return false
  }

  // ========================================================= find-in-list

  property bool finding: false
  property string findTerm: ""
  property int findOrigin: 0

  function beginFind() {
    var list = paneList()
    if (!list) return
    findOrigin = list.currentIndex
    findTerm = ""
    finding = true
    findField.text = ""
    Qt.callLater(function() { findField.forceActiveFocus() })
  }

  function stepFind(direction) {
    var list = paneList()
    if (!list || findTerm === "") return
    var index = list.findNext(findTerm, list.currentIndex, direction)
    if (index >= 0) list.moveTo(index)
  }

  function endFind(keep) {
    var list = paneList()
    if (!keep && list) list.moveTo(findOrigin)
    finding = false
    findField.focus = false
    Qt.callLater(function() { keyCatcher.forceActiveFocus() })
  }

  // ============================================================== the keys

  property string pendingKey: ""

  Timer {
    id: pendingTimer
    interval: 900
    repeat: false
    onTriggered: root.pendingKey = ""
  }

  function armPending(key) {
    pendingKey = key
    pendingTimer.restart()
  }

  // The g-prefixed sequences: gg to the top, gt/gT between tabs.
  function handlePending(text) {
    var pending = pendingKey
    pendingKey = ""
    pendingTimer.stop()
    if (pending !== "g") return false
    var list = paneList()
    if (text === "g") { if (list) list.toTop(); return true }
    if (text === "t") { switchTab(1); return true }
    if (text === "T") { switchTab(-1); return true }
    return true  // an unknown second key ends the sequence rather than acting
  }

  function handleKey(event) {
    if (!service) return

    var text = String(event.text || "")
    var key = event.key
    var ctrl = (event.modifiers & Qt.ControlModifier) !== 0
    var shift = (event.modifiers & Qt.ShiftModifier) !== 0
    var list = paneList()
    var view = pane()

    // While a text field has the keyboard, only the keys it will not use can
    // mean anything here.
    var typing = finding || (view && view.inputFocused === true)

    if (key === Qt.Key_Escape) {
      if (finding) endFind(false)
      else if (typing) callPane("blurInput")
      else close()
      event.accepted = true
      return
    }

    if (finding) {
      if (key === Qt.Key_Return || key === Qt.Key_Enter) {
        endFind(true)
        event.accepted = true
      }
      return  // everything else belongs to the field
    }

    if (typing) {
      // Tab still walks the tabs while the search box has the keyboard: it is
      // the one key a single-line field has no use for.
      if (key === Qt.Key_Tab || key === Qt.Key_Backtab) {
        switchTab(key === Qt.Key_Backtab || shift ? -1 : 1)
        event.accepted = true
      }
      return
    }

    if (pendingKey !== "" && text !== "") {
      if (handlePending(text)) {
        event.accepted = true
        return
      }
    }

    if (ctrl) {
      if (key === Qt.Key_D) { if (list) list.halfPageDown(); event.accepted = true; return }
      if (key === Qt.Key_U) { if (list) list.halfPageUp(); event.accepted = true; return }
      if (key === Qt.Key_F) { if (list) list.pageDown(); event.accepted = true; return }
      if (key === Qt.Key_B) { if (list) list.pageUp(); event.accepted = true; return }
      if (key === Qt.Key_Space) { if (list) list.invertMarks(); event.accepted = true; return }
      if (key === Qt.Key_C) { close(); event.accepted = true; return }
      return
    }

    switch (key) {
      case Qt.Key_Tab:
      case Qt.Key_Backtab:
        switchTab(key === Qt.Key_Backtab || shift ? -1 : 1)
        event.accepted = true
        return
      case Qt.Key_Down:
        if (list) list.move(1); event.accepted = true; return
      case Qt.Key_Up:
        if (list) list.move(-1); event.accepted = true; return
      case Qt.Key_Right:
        callPane("descend"); event.accepted = true; return
      case Qt.Key_Left:
        callPane("ascend"); event.accepted = true; return
      case Qt.Key_PageDown:
        if (list) list.pageDown(); event.accepted = true; return
      case Qt.Key_PageUp:
        if (list) list.pageUp(); event.accepted = true; return
      case Qt.Key_Home:
        if (list) list.toTop(); event.accepted = true; return
      case Qt.Key_End:
        if (list) list.toBottom(); event.accepted = true; return
      case Qt.Key_Return:
      case Qt.Key_Enter:
        callPane("activate"); event.accepted = true; return
      case Qt.Key_Space:
        if (list) list.toggleMark(list.currentIndex)
        event.accepted = true
        return
    }

    if (text === "") return
    event.accepted = true

    switch (text) {
      // ---- moving
      case "j": if (list) list.move(1); return
      case "k": if (list) list.move(-1); return
      case "l": callPane("descend"); return
      case "h": callPane("ascend"); return
      case "g": armPending("g"); return
      case "G": if (list) list.toBottom(); return
      case "/": beginFind(); return
      case "n": stepFind(1); return
      case "N": stepFind(-1); return

      // ---- the queue and the library
      case "a": callPane("addSelected", false); return
      case "A": callPane("addAll"); return
      case "d": callPane("deleteSelected"); return
      case "D": callPane("deleteAll"); return
      case "J": callPane("moveBy", 1); return
      case "K": callPane("moveBy", -1); return
      case "C": callPane("jumpToCurrent"); return
      case "X": callPane("shuffle"); return
      case "i": callPane("focusInput"); return

      // ---- the server
      case "p": service.toggle(); return
      case "s": service.stop(); return
      case ">": service.next(); return
      case "<": service.previous(); return
      case "f": service.seek(service.elapsed + 5); return
      case "b": service.seek(Math.max(0, service.elapsed - 5)); return
      case ".":
      case "+": service.nudgeVolume(5); return
      case ",":
      case "-": service.nudgeVolume(-5); return
      case "z": service.toggleOption("repeat"); return
      case "x": service.toggleOption("random"); return
      case "c": service.toggleOption("consume"); return
      case "v": service.toggleOption("single"); return
      case "u": service.updateDatabase(); return
      case "U": service.rescanDatabase(); return

      // ---- the panel
      case "q": close(); return
      case "?": helpShown = !helpShown; return
    }

    // A digit picks a tab, the way rmpc's 1-7 do.
    if (text >= "1" && text <= "9") {
      goToTab(Number(text) - 1)
      return
    }

    event.accepted = false
  }

  property bool helpShown: false

  onOpenChanged: {
    if (!open) {
      finding = false
      helpShown = false
      pendingKey = ""
      return
    }
    Qt.callLater(function() { keyCatcher.forceActiveFocus() })
  }

  // ================================================================ panel

  KeyboardPanel {
    id: panel
    anchorItem: root.anchorItem
    owner: ownerProxy
    bar: root.bar
    open: root.open
    focusTarget: keyCatcher
    centerOnBar: true
    // As big as the screen allows up to the size the layout was drawn for.
    // A table of four columns and a cover beside it needs the room; a laptop
    // gets whatever it has.
    contentWidth: panel.fittedContentWidth(Style.space(1180))
    contentHeight: panel.cappedContentHeight(Style.space(760))

    Item {
      id: keyCatcher
      anchors.fill: parent
      focus: true
      // Keys reach the focused item first -- a text field, when one has the
      // keyboard -- and arrive here only if it had no use for them.
      Keys.onPressed: function(event) { root.handleKey(event) }

      // ------------------------------------------------------- the header

      Rectangle {
        id: header
        anchors { top: parent.top; left: parent.left; right: parent.right }
        height: Math.round(root.fontSizeBody * 3.6)
        color: "transparent"
        border.width: Style.normalBorderWidth
        border.color: root.line
        radius: Style.cornerRadius

        Item {
          anchors.fill: parent
          anchors.margins: Style.space(8)

          // What the server is doing, and how far into it.
          Column {
            id: headerLeft
            anchors { left: parent.left; verticalCenter: parent.verticalCenter }
            width: Math.round(parent.width * 0.26)
            spacing: Style.space(2)

            Text {
              text: {
                if (!root.connected) return "[Offline]"
                if (root.service.isPlaying) return "[Playing]"
                if (root.service.isPaused) return "[Paused]"
                return "[Stopped]"
              }
              color: root.connected && root.service.isPlaying ? root.accent : root.dim
              font.family: root.fontFamily
              font.pixelSize: root.fontSizeBody
              font.bold: true
            }

            Text {
              text: {
                if (!root.connected) return root.service && root.service.lastError !== ""
                  ? root.service.lastError : "connecting…"
                if (!root.hasSong) return root.service.target
                var line = root.service.formatTime(root.service.elapsed)
                  + " / " + root.service.formatTime(root.service.duration)
                if (root.service.bitrate !== "") line += " (" + root.service.bitrate + " kbps)"
                return line
              }
              color: root.dim
              font.family: root.fontFamily
              font.pixelSize: root.fontSizeSmall
              elide: Text.ElideRight
              width: headerLeft.width
            }
          }

          // What is playing.
          Column {
            anchors { horizontalCenter: parent.horizontalCenter; verticalCenter: parent.verticalCenter }
            width: Math.round(parent.width * 0.44)
            spacing: Style.space(2)

            Text {
              width: parent.width
              horizontalAlignment: Text.AlignHCenter
              text: root.hasSong ? root.service.songTitle(root.service.song)
                                 : (root.connected ? "Nothing playing" : "MPD")
              color: root.hasSong ? root.accent : root.dim
              font.family: root.fontFamily
              font.pixelSize: root.fontSizeBody
              font.bold: true
              elide: Text.ElideRight
            }

            Text {
              width: parent.width
              horizontalAlignment: Text.AlignHCenter
              text: {
                if (!root.hasSong) return ""
                var song = root.service.song
                var artist = String(song.artist || song.albumartist || "")
                var album = String(song.album || "")
                if (artist === "" && album === "") return ""
                if (artist === "") return album
                return album === "" ? artist : artist + " – " + album
              }
              color: root.fg
              font.family: root.fontFamily
              font.pixelSize: root.fontSizeSmall
              elide: Text.ElideRight
            }
          }

          // The volume, and the four options that belong to the server.
          Column {
            id: headerRight
            anchors { right: parent.right; verticalCenter: parent.verticalCenter }
            width: Math.round(parent.width * 0.26)
            spacing: Style.space(4)

            Row {
              anchors.right: parent.right
              spacing: Style.space(6)

              Text {
                anchors.verticalCenter: parent.verticalCenter
                text: root.connected && root.service.volume < 0 ? "No mixer" : "Volume:"
                color: root.dim
                font.family: root.fontFamily
                font.pixelSize: root.fontSizeSmall
              }

              // A bar rather than a number alone, which is what rmpc shows and
              // what makes 60 mean something at a glance.
              Rectangle {
                visible: root.connected && root.service.volume >= 0
                anchors.verticalCenter: parent.verticalCenter
                width: Style.space(60)
                height: Math.max(3, Style.space(4))
                radius: Style.cornerRadius
                color: root.rule

                Rectangle {
                  width: parent.width * Math.max(0, Math.min(1,
                    (root.connected ? root.service.volume : 0) / 100))
                  height: parent.height
                  color: root.accent
                }

                MouseArea {
                  anchors.fill: parent
                  anchors.margins: -Style.space(4)
                  onClicked: function(mouse) {
                    if (root.service) root.service.setVolume(Math.round(100 * mouse.x / width))
                  }
                }
              }

              Text {
                visible: root.connected && root.service.volume >= 0
                anchors.verticalCenter: parent.verticalCenter
                text: (root.connected ? root.service.volume : 0) + "%"
                color: root.fg
                font.family: root.fontFamily
                font.pixelSize: root.fontSizeSmall
              }
            }

            Row {
              anchors.right: parent.right
              spacing: Style.space(8)

              Repeater {
                model: [
                  { glyph: "󰑖", option: "repeat", tip: "Repeat  (z)" },
                  { glyph: "󰒟", option: "random", tip: "Random  (x)" },
                  { glyph: "󰑘", option: "single", tip: "Single  (v)" },
                  { glyph: "󰆴", option: "consume", tip: "Consume  (c)" }
                ]

                delegate: Text {
                  id: optionGlyph
                  required property var modelData

                  readonly property bool on: {
                    if (!root.connected) return false
                    if (optionGlyph.modelData.option === "repeat") return root.service.repeatOn
                    if (optionGlyph.modelData.option === "random") return root.service.randomOn
                    if (optionGlyph.modelData.option === "single") return root.service.singleMode !== "0"
                    return root.service.consumeOn
                  }

                  text: optionGlyph.modelData.glyph
                  color: optionGlyph.on ? root.accent : root.rule
                  font.family: root.fontFamily
                  font.pixelSize: root.fontSizeBody

                  MouseArea {
                    anchors.fill: parent
                    anchors.margins: -Style.space(3)
                    cursorShape: Qt.PointingHandCursor
                    onClicked: if (root.service) root.service.toggleOption(optionGlyph.modelData.option)
                  }
                }
              }
            }
          }
        }
      }

      // --------------------------------------------------------- the tabs

      Rectangle {
        id: tabBar
        anchors { top: header.bottom; topMargin: Style.spacing.md; left: parent.left; right: parent.right }
        height: Math.round(root.fontSizeBody * 2.4)
        color: "transparent"
        border.width: Style.normalBorderWidth
        border.color: root.line
        radius: Style.cornerRadius

        Row {
          anchors.centerIn: parent
          spacing: Style.space(4)

          Repeater {
            model: root.tabs

            delegate: Rectangle {
              id: tabChip
              required property var modelData
              required property int index

              readonly property bool current: tabChip.index === root.tabIndex

              width: label.implicitWidth + Style.space(20)
              height: Math.round(root.fontSizeBody * 1.7)
              color: tabChip.current ? Color.menu.selectedBackground : "transparent"
              radius: Style.cornerRadius

              Text {
                id: label
                anchors.centerIn: parent
                // The number is how the tab is reached from the keyboard, so it
                // is written where the eye already is.
                text: (tabChip.index + 1) + " " + tabChip.modelData.label
                color: tabChip.current ? Color.menu.selectedText : root.dim
                font.family: root.fontFamily
                font.pixelSize: root.fontSizeSmall
                font.bold: tabChip.current
              }

              MouseArea {
                anchors.fill: parent
                cursorShape: Qt.PointingHandCursor
                onClicked: root.goToTab(tabChip.index)
              }
            }
          }
        }
      }

      // ------------------------------------------------------ the content

      Rectangle {
        id: content
        anchors {
          top: tabBar.bottom
          topMargin: Style.spacing.md
          left: parent.left
          right: parent.right
          bottom: footer.top
          bottomMargin: Style.spacing.md
        }
        color: "transparent"
        border.width: Style.normalBorderWidth
        border.color: root.line
        radius: Style.cornerRadius
        clip: true

        Item {
          id: paneArea
          anchors.fill: parent
          anchors.margins: Style.space(8)
          anchors.bottomMargin: root.finding ? Style.space(8) + findRow.height : Style.space(8)

          QueueView {
            id: queueView
            anchors.fill: parent
            visible: root.tab === "queue"
            active: visible && root.open
            service: root.service
            fontFamily: root.fontFamily
            fontSize: root.fontSizeSmall
            foreground: root.fg
            accent: root.accent

          }

          BrowserView {
            id: directoriesView
            anchors.fill: parent
            visible: root.tab === "directories"
            active: visible && root.open
            mode: "directories"
            service: root.service
            fontFamily: root.fontFamily
            fontSize: root.fontSizeSmall
            foreground: root.fg
            accent: root.accent

          }

          BrowserView {
            id: artistsView
            anchors.fill: parent
            visible: root.tab === "artists"
            active: visible && root.open
            mode: "artist"
            service: root.service
            fontFamily: root.fontFamily
            fontSize: root.fontSizeSmall
            foreground: root.fg
            accent: root.accent

          }

          BrowserView {
            id: albumArtistsView
            anchors.fill: parent
            visible: root.tab === "albumartists"
            active: visible && root.open
            mode: "albumartist"
            service: root.service
            fontFamily: root.fontFamily
            fontSize: root.fontSizeSmall
            foreground: root.fg
            accent: root.accent

          }

          BrowserView {
            id: albumsView
            anchors.fill: parent
            visible: root.tab === "albums"
            active: visible && root.open
            mode: "album"
            service: root.service
            fontFamily: root.fontFamily
            fontSize: root.fontSizeSmall
            foreground: root.fg
            accent: root.accent

          }

          BrowserView {
            id: genreView
            anchors.fill: parent
            visible: root.tab === "genre"
            active: visible && root.open
            mode: "genre"
            service: root.service
            fontFamily: root.fontFamily
            fontSize: root.fontSizeSmall
            foreground: root.fg
            accent: root.accent

          }

          BrowserView {
            id: playlistsView
            anchors.fill: parent
            visible: root.tab === "playlists"
            active: visible && root.open
            mode: "playlists"
            service: root.service
            fontFamily: root.fontFamily
            fontSize: root.fontSizeSmall
            foreground: root.fg
            accent: root.accent

          }

          SettingsView {
            id: settingsView
            anchors.fill: parent
            visible: root.tab === "settings"
            active: visible && root.open
            service: root.service
            bar: root.bar
            settings: root.widgetSettings
            version: root.version
            pythonPresent: root.pythonPresent
            fontFamily: root.fontFamily
            foreground: root.fg
            accent: root.accent
            onPersistRequested: function(key, value) { root.persistRequested(key, value) }
          }

          SearchView {
            id: searchView
            anchors.fill: parent
            visible: root.tab === "search"
            active: visible && root.open
            service: root.service
            fontFamily: root.fontFamily
            fontSize: root.fontSizeSmall
            foreground: root.fg
            accent: root.accent

          }
        }

        // `/` -- jump to a row by what it says, in whichever list is showing.
        Row {
          id: findRow
          visible: root.finding
          anchors { left: parent.left; right: parent.right; bottom: parent.bottom }
          anchors.margins: Style.space(8)
          height: visible ? Math.round(root.fontSizeBody * 2.2) : 0
          spacing: Style.space(6)

          Text {
            anchors.verticalCenter: parent.verticalCenter
            text: "/"
            color: root.accent
            font.family: root.fontFamily
            font.pixelSize: root.fontSizeBody
          }

          TextField {
            id: findField
            width: parent.width - Style.space(24)
            foreground: root.fg
            placeholderText: "jump to…  (enter keeps it, esc goes back)"
            onTextChanged: {
              root.findTerm = text
              var list = root.paneList()
              if (!list || text === "") return
              // From one before the origin, so the first match found is the
              // one at the cursor rather than the one after it.
              var index = list.findNext(text, root.findOrigin - 1, 1)
              if (index >= 0) list.moveTo(index)
            }
          }
        }

        // ------------------------------------------------------ the help

        Rectangle {
          anchors.fill: parent
          visible: root.helpShown
          color: Qt.rgba(root.bg.r, root.bg.g, root.bg.b, 0.96)

          MouseArea {
            anchors.fill: parent
            onClicked: root.helpShown = false
          }

          Grid {
            anchors.centerIn: parent
            columns: 4
            rowSpacing: Style.space(4)
            columnSpacing: Style.space(14)

            Repeater {
              model: [
                "j k", "move", "p", "play / pause",
                "g g", "top", "s", "stop",
                "G", "bottom", "< >", "previous / next",
                "^u ^d", "half page", "f b", "seek ±5s",
                "^b ^f", "page", ". ,", "volume ±5",
                "h l", "out / in", "z", "repeat",
                "enter", "play it", "x", "random",
                "a A", "add / add all", "c", "consume",
                "d D", "delete / clear", "v", "single",
                "space", "mark", "u U", "update / rescan",
                "/ n N", "find, again, back", "tab 1-9", "switch tab",
                "J K", "move in queue", "C", "jump to playing",
                "X", "shuffle queue", "i", "search box",
                "?", "this", "q esc", "close"
              ]

              delegate: Text {
                id: helpCell
                required property var modelData
                required property int index

                text: helpCell.modelData
                color: helpCell.index % 2 === 0 ? root.accent : root.dim
                font.family: root.fontFamily
                font.pixelSize: root.fontSizeSmall
                font.bold: helpCell.index % 2 === 0
              }
            }
          }
        }
      }

      // ----------------------------------------------------- the progress

      Rectangle {
        id: footer
        anchors { bottom: parent.bottom; left: parent.left; right: parent.right }
        height: Math.round(root.fontSizeBody * 2.4)
        color: "transparent"
        border.width: Style.normalBorderWidth
        border.color: root.line
        radius: Style.cornerRadius

        Item {
          anchors.fill: parent
          anchors.leftMargin: Style.space(10)
          anchors.rightMargin: Style.space(10)

          Text {
            id: stateGlyph
            anchors.verticalCenter: parent.verticalCenter
            text: root.connected ? root.service.stateIcon : "󰝛"
            color: root.connected && root.service.isPlaying ? root.accent : root.dim
            font.family: root.fontFamily
            font.pixelSize: root.fontSizeBody

            MouseArea {
              anchors.fill: parent
              anchors.margins: -Style.space(4)
              cursorShape: Qt.PointingHandCursor
              onClicked: if (root.service) root.service.toggle()
            }
          }

          Text {
            id: clock
            anchors { right: parent.right; verticalCenter: parent.verticalCenter }
            text: root.hasSong
              ? root.service.formatTime(root.service.elapsed) + " / "
                + root.service.formatTime(root.service.duration)
              : "--:-- / --:--"
            color: root.dim
            font.family: root.fontFamily
            font.pixelSize: root.fontSizeSmall
          }

          // Click anywhere along it to seek there, which a terminal cannot do
          // and a panel may as well.
          Rectangle {
            id: track
            anchors {
              left: stateGlyph.right
              leftMargin: Style.space(10)
              right: clock.left
              rightMargin: Style.space(10)
              verticalCenter: parent.verticalCenter
            }
            height: Math.max(4, Style.space(6))
            color: root.rule
            radius: height / 2

            Rectangle {
              width: {
                if (!root.hasSong || root.service.duration <= 0) return 0
                var fraction = root.service.elapsed / root.service.duration
                return Math.round(parent.width * Math.max(0, Math.min(1, fraction)))
              }
              height: parent.height
              radius: parent.radius
              color: root.accent
            }

            MouseArea {
              anchors.fill: parent
              anchors.topMargin: -Style.space(6)
              anchors.bottomMargin: -Style.space(6)
              cursorShape: Qt.PointingHandCursor
              enabled: root.hasSong && root.connected
              onClicked: function(mouse) {
                if (!root.service || root.service.duration <= 0) return
                root.service.seek(root.service.duration * Math.max(0, Math.min(1, mouse.x / width)))
              }
            }
          }
        }
      }
    }
  }

  // Font sizes are read once here so every pane is measured against the same
  // two numbers rather than against Style directly.
  readonly property int fontSizeBody: Style.font.body
  readonly property int fontSizeSmall: Style.font.bodySmall
}
