import QtQuick
import Quickshell
import Quickshell.Io
import qs.Commons
import qs.Ui
import "Format.js" as Format

// Bar strip, client panel and settings panel for the MPD client.
//
// The strip is assembled out of optional parts -- cover, state glyph, label,
// transport, gear -- because a bar is short and everyone draws the line
// somewhere different. All of them can be turned off; the gear is what is left
// when they all are.
//
// Two panels hang off it, and they are different things. Clicking the label
// opens the client (ClientPanel.qml): the queue, the library, search, the
// keyboard. The gear opens this file's own settings panel, which is about the
// widget rather than about the music. The bar's popout coordinator makes sure
// only one of them is up at a time.
//
// Nothing here talks to MPD. The connection lives in Service.qml, one for the
// shell rather than one per monitor, and this reads it back through
// shell.serviceFor(). Settings are written the only way plugin settings can be
// persisted -- `omarchy-shell shell setBarWidget` -- so the shell stays the
// sole writer of shell.json, and the service picks the change up from there.
Panel {
  id: root
  moduleName: "matjam.omajam"
  ipcTarget: "matjam.omajam"
  manageIpc: false

  readonly property var service: bar && bar.shell ? bar.shell.serviceFor(moduleName) : null

  readonly property bool vertical: bar ? bar.vertical : false
  readonly property int barSize: bar ? bar.barSize : Style.bar.sizeHorizontal
  readonly property color fg: bar ? bar.barForeground : Color.foreground
  readonly property string fontFamily: bar ? bar.fontFamily : Style.font.family

  // ------------------------------------------------------------- settings

  readonly property string format: String(setting("format", "[%artist% - ][%title%|%filename%]"))
  readonly property int maxWidth: Math.max(40, Number(setting("maxWidth", 240)) || 240)
  readonly property string overflow: String(setting("overflow", "scroll")) === "elide" ? "elide" : "scroll"
  readonly property bool showControls: setting("showControls", true) === true
  readonly property string controlsPosition: String(setting("controlsPosition", "right")) === "left" ? "left" : "right"
  readonly property bool showStop: setting("showStop", false) === true
  readonly property bool showStateIcon: setting("showStateIcon", true) === true
  readonly property bool showArt: setting("showArt", false) === true
  readonly property bool showSettingsButton: setting("showSettingsButton", true) === true
  readonly property string whenIdle: String(setting("whenIdle", "icon")) === "hide" ? "hide" : "icon"
  readonly property string wheelAction: {
    var value = String(setting("wheelAction", "volume"))
    return ["volume", "seek", "track", "none"].indexOf(value) !== -1 ? value : "volume"
  }

  // ---------------------------------------------------------------- state

  readonly property bool connected: !!service && service.connected
  readonly property bool hasSong: connected && service.hasSong
  readonly property bool playing: connected && service.isPlaying

  // Nothing to say and nothing to control. The gear survives it, unless the
  // user asked for the widget to disappear outright.
  readonly property bool idle: !connected || !hasSong

  readonly property string label: hasSong ? Format.render(format, service.tokens) : ""

  // The cover carrying the widget on its own: no label, no play glyph. It then
  // stands in for the icon every other bar widget has, and an icon the size of
  // a postage stamp is not one. Set the format to nothing to get here.
  readonly property bool artIsTheIcon: showArt && !showStateIcon && label === ""

  readonly property string stateGlyph: {
    if (!connected) return "󰝛"
    if (!service.hasSong) return "󰝚"
    return service.stateIcon
  }

  readonly property string version: {
    try {
      return String(bar.shell.pluginRegistry.installedPlugins[moduleName].version || "")
    } catch (e) {
      return ""
    }
  }

  visible: !(idle && whenIdle === "hide") || clientOpen
  implicitWidth: visible ? (vertical ? barSize : strip.implicitWidth) : 0
  implicitHeight: visible ? (vertical ? strip.implicitHeight : barSize) : 0

  Behavior on implicitWidth {
    enabled: !root.vertical
    NumberAnimation { duration: 180; easing.type: Easing.OutCubic }
  }

  // ------------------------------------------------------------- actions

  function toggleTrack() { if (service) service.toggle() }
  function nextTrack() { if (service) service.next() }
  function previousTrack() { if (service) service.previous() }
  function stopPlayback() { if (service) service.stop() }

  // The window is this widget's panel, so it uses the Panel base's own
  // open/close/opened rather than a second lifecycle beside it. The shell
  // summons bar widgets through exactly those three -- see Bar.findPanelWidget,
  // which is also what picks the copy on the focused monitor -- so anything
  // less would leave `omarchy-shell shell toggle matjam.omajam` opening
  // nothing.
  readonly property bool clientOpen: opened

  // Routed through the shell when it can be. A bar widget exists once per
  // monitor but answers IPC once, so acting on `this` would open the window on
  // whichever copy happened to register the target. The shell picks the copy on
  // the monitor with focus, which is the one whose keyboard just asked.
  function viaShell(name) {
    var shell = bar ? bar.shell : null
    if (!shell || typeof shell[name] !== "function") return false
    return shell[name](moduleName) !== false
  }

  // The window of whichever copy of this widget the shell would act on: the one
  // already open, else the one on the focused monitor. IPC arrives at a single
  // copy -- whichever registered the target -- so without this, `key` and
  // `state` would drive a different window from the one `show` opened, on a
  // different monitor, with its panes never loaded.
  readonly property var panel: clientPanel

  function targetPanel() {
    if (bar && typeof bar.findPanelWidget === "function") {
      var item = bar.findPanelWidget(moduleName)
      if (item && item.panel) return item.panel
    }
    return clientPanel
  }

  function openClient() { if (!viaShell("summon")) open() }
  function closeClient() { if (!viaShell("hide")) close() }
  function toggleClient() { if (!viaShell("toggle")) toggle() }

  // The settings live in the window now, as its last tab. The cog opens it
  // there; a second press closes it again rather than doing nothing.
  function toggleSettings() {
    if (opened && clientPanel.tab === "settings") {
      close()
      return
    }
    clientPanel.openSettings()
    open()
  }

  function handleWheel(delta) {
    if (!service || !connected) return
    if (wheelAction === "volume") {
      service.nudgeVolume(delta > 0 ? 5 : -5)
    } else if (wheelAction === "seek") {
      service.seek(Math.max(0, service.elapsed + (delta > 0 ? 5 : -5)))
    } else if (wheelAction === "track") {
      // Up for the previous track, matching the direction a list scrolls.
      if (delta > 0) previousTrack()
      else nextTrack()
    }
  }

  IpcHandler {
    target: root.ipcTarget
    // These meant the settings popup before the settings moved into the
    // client. They mean the client now, which is where they end up either way.
    function open(): void { root.openClient() }
    function close(): void { root.closeClient() }
    function toggle(): void { root.toggleClient() }
    // The client panel -- the thing worth binding a key to.
    function client(): void { root.toggleClient() }
    function show(): void { root.openClient() }
    function hide(): void { root.closeClient() }
    function settings(): void { root.toggleSettings() }

    // Open the window on Search, looking for something:
    //   omarchy-shell matjam.omajam search "hounds of love"
    function search(term: string): void {
      root.openClient()
      clientPanel.searchFor(String(term))
    }

    // Drive the window from a script or a keybind, with the same keys it takes
    // from the keyboard: `omarchy-shell matjam.omajam key a` adds what is under
    // the cursor. The keys that carry no text have names -- esc, enter, tab,
    // up, down, left, right, space, pgup, pgdn, home, end. Only meaningful
    // while the window is open.
    function key(text: string): void {
      var panel = root.targetPanel()
      var name = String(text)
      var named = {
        esc: Qt.Key_Escape, escape: Qt.Key_Escape, enter: Qt.Key_Return,
        ret: Qt.Key_Return, tab: Qt.Key_Tab, backtab: Qt.Key_Backtab,
        up: Qt.Key_Up, down: Qt.Key_Down, left: Qt.Key_Left, right: Qt.Key_Right,
        space: Qt.Key_Space, pgup: Qt.Key_PageUp, pgdn: Qt.Key_PageDown,
        home: Qt.Key_Home, end: Qt.Key_End
      }
      var code = named[name.toLowerCase()]
      panel.handleKey({
        key: code === undefined ? 0 : code,
        text: code === undefined ? name : "",
        modifiers: 0,
        accepted: false
      })
    }

    // What the window is showing, for a script -- and for working out why it is
    // showing that.
    function state(): string {
      var panel = root.targetPanel()
      var list = panel.paneList()
      var view = panel.pane()
      return JSON.stringify({
        service: !!root.service,
        connected: root.connected,
        open: panel.open,
        tab: panel.tab,
        rows: list ? list.count : -1,
        cursor: list ? list.currentIndex : -1,
        marked: list ? list.markedCount : -1,
        levels: (view && view.levels !== undefined) ? view.levels.length : -1,
        databaseVersion: root.service ? root.service.databaseVersion : -1,
        finding: panel.finding,
        // What the strip itself is showing, which is the other half of any
        // question about this widget.
        strip: {
          "label": root.label,
          "art": root.artSource,
          "showArt": root.showArt,
          "hasSong": root.hasSong,
          "stripWidth": root.implicitWidth
        },
        row: list ? list.currentRow : null
      })
    }
  }

  // ------------------------------------------------------------ the strip
  //
  // Grid rather than Row so the same children stack for a side bar: with rows
  // set to 1 it is a row, and with rows unbounded it is a column. Everything in
  // it is either fixed-size or hidden when vertical, so no cell has to stretch.
  Grid {
    id: strip
    anchors.centerIn: parent
    rows: root.vertical ? 99 : 1
    spacing: 0

    Loader {
      active: root.showControls && !root.idle && root.controlsPosition === "left"
      visible: active
      sourceComponent: transportComponent
    }

    // Cover, state glyph and label together: one hover target, one click
    // target, and the thing the tooltip is anchored to.
    Item {
      id: nowPlaying
      // Nothing to show is a real state -- every part turned off, or a vertical
      // bar where the label cannot go -- and an empty block would still claim
      // its padding and leave a gap in the strip.
      visible: info.implicitWidth > 0
      implicitWidth: root.vertical ? root.barSize : info.implicitWidth + Style.space(10)
      implicitHeight: root.vertical ? info.implicitHeight + Style.space(8) : root.barSize

      readonly property bool hovered: pointer.containsMouse
      // What the bar's own tooltip machinery looks for when deciding whether a
      // tooltip request is still wanted.
      readonly property bool tooltipHovered: visible && pointer.containsMouse

      Row {
        id: info
        anchors.centerIn: parent
        spacing: Style.space(6)

        // Sized through implicitWidth rather than width: a positioner works
        // out its own implicit size from its children's, and a child that
        // only sets width contributes nothing to it -- which collapses the
        // strip to the width of the glyph.
        Rectangle {
          id: thumb
          visible: root.showArt && root.hasSong && root.artSource !== ""
          implicitWidth: Math.round(root.barSize * (root.artIsTheIcon ? 0.78 : 0.62))
          implicitHeight: implicitWidth
          radius: Style.cornerRadius > 0 ? Style.space(2) : 0
          color: "transparent"
          clip: true
          anchors.verticalCenter: parent.verticalCenter

          // Decoded at the size it is drawn rather than at the cover's own:
          // a 1400px scan decoded to fill sixteen pixels would cost megabytes
          // to draw something the size of a fingernail.
          Image {
            anchors.fill: parent
            source: root.artSource
            fillMode: Image.PreserveAspectCrop
            asynchronous: true
            cache: true
            sourceSize.width: 64
          }
        }

        Text {
          id: glyph
          // Kept when idle even if the user turned it off, because idle is
          // exactly when it is the only thing left to click on.
          visible: root.showStateIcon || root.idle
          anchors.verticalCenter: parent.verticalCenter
          text: root.stateGlyph
          color: root.playing ? root.fg : Qt.darker(root.fg, 1.5)
          font.family: root.fontFamily
          font.pixelSize: Style.font.body

          Behavior on color {
            enabled: !root.bar || root.bar.foregroundAnimationEnabled
            ColorAnimation { duration: 160 }
          }
        }

        // Clipped rather than sized to the text: a long title should cost the
        // bar a fixed amount of room and scroll inside it.
        Item {
          id: labelClip
          visible: !root.vertical && root.label !== ""
          implicitWidth: Math.min(root.maxWidth, labelText.implicitWidth)
          implicitHeight: labelText.implicitHeight
          clip: true
          anchors.verticalCenter: parent.verticalCenter

          Text {
            id: labelText
            text: root.label
            color: root.fg
            font.family: root.fontFamily
            font.pixelSize: Style.font.body
            anchors.verticalCenter: parent.verticalCenter
            width: root.overflow === "elide" ? labelClip.width : implicitWidth
            elide: root.overflow === "elide" ? Text.ElideRight : Text.ElideNone

            readonly property bool needsScroll: root.overflow === "scroll"
              && implicitWidth > labelClip.width

            // Paused deliberately while the panel or the hover card is up: the
            // card already shows the whole title, and text sliding under an
            // open panel reads as something still loading.
            NumberAnimation on x {
              running: labelText.needsScroll && !root.clientOpen && !root.previewShown
              loops: Animation.Infinite
              duration: Math.max(6000, labelText.implicitWidth * 25)
              from: labelClip.width
              to: -labelText.implicitWidth
              easing.type: Easing.Linear
            }

            // Without this the text keeps whatever offset the animation left
            // behind when it stops, which on a title that has just become short
            // enough to fit leaves it parked off the left edge.
            onNeedsScrollChanged: if (!needsScroll) x = 0
          }
        }
      }

      MouseArea {
        id: pointer
        anchors.fill: parent
        hoverEnabled: true
        cursorShape: Qt.PointingHandCursor
        acceptedButtons: Qt.LeftButton | Qt.RightButton | Qt.MiddleButton

        onClicked: function(mouse) {
          // Left opens the client, which is the thing this widget is a handle
          // for; the transport buttons beside it are how you play and pause
          // without opening anything.
          if (mouse.button === Qt.RightButton) root.toggleSettings()
          else if (mouse.button === Qt.MiddleButton) root.nextTrack()
          else root.toggleClient()
        }
        onWheel: function(wheel) { root.handleWheel(wheel.angleDelta.y) }
      }
    }

    Loader {
      active: root.showControls && !root.idle && root.controlsPosition === "right"
      visible: active
      sourceComponent: transportComponent
    }

    BarIconButton {
      id: gearButton
      visible: root.showSettingsButton
      bar: root.bar
      text: "󰒓"
      tooltipText: "omajam settings"
      active: root.clientOpen && clientPanel.tab === "settings"
      onPressed: function(buttonCode) { root.toggleSettings() }
    }
  }

  // One definition, loaded on whichever side of the label the user put it.
  Component {
    id: transportComponent

    Grid {
      rows: root.vertical ? 99 : 1
      spacing: 0

      BarIconButton {
        bar: root.bar
        text: "󰒮"
        tooltipText: "Previous"
        onPressed: function(buttonCode) { root.previousTrack() }
      }

      BarIconButton {
        bar: root.bar
        text: root.playing ? "󰏤" : "󰐊"
        tooltipText: root.playing ? "Pause" : "Play"
        onPressed: function(buttonCode) { root.toggleTrack() }
      }

      BarIconButton {
        visible: root.showStop
        bar: root.bar
        text: "󰓛"
        tooltipText: "Stop"
        onPressed: function(buttonCode) { root.stopPlayback() }
      }

      BarIconButton {
        bar: root.bar
        text: "󰒭"
        tooltipText: "Next"
        onPressed: function(buttonCode) { root.nextTrack() }
      }
    }
  }

  // ------------------------------------------------------------ hover card
  //
  // A window of our own rather than the bar's tooltip, which takes a line of
  // text and nothing else -- and the cover is the point. Staying outside the
  // bar's popout coordinator also means a pointer crossing the strip cannot
  // close a panel that is open elsewhere.

  // The cover for whatever is playing. The service resolves it, because where
  // it comes from depends on the source: a file the bridge wrote for MPD, and
  // for MPRIS whatever URL the player advertises -- a local file from a
  // browser, an https:// one from Spotify. Qt's Image loads all three.
  readonly property string artSource: service ? service.artSource : ""

  property bool previewShown: false

  Timer {
    id: previewDelay
    interval: 400
    repeat: false
    onTriggered: root.previewShown = nowPlaying.hovered && !root.clientOpen
  }

  Connections {
    target: nowPlaying
    function onHoveredChanged() {
      if (!nowPlaying.hovered || root.clientOpen) {
        previewDelay.stop()
        root.previewShown = false
        return
      }
      previewDelay.restart()
    }
  }

  // The cog and a right-click both land on the settings tab of the client, and
  // the python probe only has to run once there is somewhere to show it.
  onOpenedChanged: {
    if (!opened) return
    previewDelay.stop()
    previewShown = false
    if (!pythonProbe.running) pythonProbe.running = true
  }

  PopupWindow {
    id: preview

    readonly property var anchorWindow: nowPlaying.QsWindow ? nowPlaying.QsWindow.window : null
    readonly property int gap: Style.space(6)
    readonly property string barPosition: root.bar ? root.bar.position : "top"

    visible: root.previewShown && !!anchorWindow
    color: "transparent"
    implicitWidth: Math.ceil(previewCard.implicitWidth)
    implicitHeight: Math.ceil(previewCard.implicitHeight)

    // The placement the bar gives its own tooltip: off the bar's inner edge,
    // centred on the strip, slid back inside the screen rather than hanging
    // over an edge.
    anchor {
      window: preview.anchorWindow
      adjustment: PopupAdjustment.Slide
      edges: Edges.Top | Edges.Left
      gravity: Edges.Bottom | Edges.Right
      rect.width: 1
      rect.height: 1

      onAnchoring: {
        var window = preview.anchorWindow
        if (!window) return

        var w = preview.implicitWidth
        var h = preview.implicitHeight
        var localX = nowPlaying.width / 2 - w / 2
        var localY = nowPlaying.height + preview.gap

        if (preview.barPosition === "bottom") {
          localY = -h - preview.gap
        } else if (preview.barPosition === "left") {
          localX = nowPlaying.width + preview.gap
          localY = nowPlaying.height / 2 - h / 2
        } else if (preview.barPosition === "right") {
          localX = -w - preview.gap
          localY = nowPlaying.height / 2 - h / 2
        }

        var point = window.contentItem.mapFromItem(nowPlaying, localX, localY)
        if (preview.barPosition === "top" || preview.barPosition === "bottom")
          point.x = Math.max(preview.gap, Math.min(point.x, window.width - w - preview.gap))
        else
          point.y = Math.max(preview.gap, Math.min(point.y, window.height - h - preview.gap))

        preview.anchor.rect.x = Math.round(point.x)
        preview.anchor.rect.y = Math.round(point.y)
      }
    }

    BorderSurface {
      id: previewCard

      readonly property color text: Color.tooltip.text
      readonly property color dim: Qt.darker(Color.tooltip.text, 1.5)

      implicitWidth: previewColumn.width + contentLeftInset + contentRightInset
      implicitHeight: previewColumn.implicitHeight + contentTopInset + contentBottomInset
      padding: Style.space(12)
      color: Color.tooltip.background
      borderSpec: Border.surfaceSpec("tooltip", "border", Color.tooltip.border, 1)
      radius: Style.cornerRadius

      Column {
        id: previewColumn
        x: previewCard.contentLeftInset
        y: previewCard.contentTopInset
        width: Style.space(240)
        spacing: Style.space(10)

        Item {
          width: parent.width
          height: width
          visible: root.artSource !== ""

          Image {
            anchors.fill: parent
            source: root.artSource
            fillMode: Image.PreserveAspectFit
            asynchronous: true
            cache: true
            // A cover is square often enough that asking for the card's width
            // is the right decode size, and never more than one screenful.
            sourceSize.width: 480
          }
        }

        // Stands in for the cover rather than collapsing the card, so a
        // library without artwork still gets a tooltip the same shape.
        Rectangle {
          visible: root.artSource === "" && root.hasSong
          width: parent.width
          height: Style.space(64)
          color: "transparent"
          border.width: Style.normalBorderWidth
          border.color: Qt.darker(previewCard.text, 2.2)

          Text {
            anchors.centerIn: parent
            text: "󰝚"
            color: Qt.darker(previewCard.text, 1.8)
            font.family: root.fontFamily
            font.pixelSize: Style.font.displayLarge
          }
        }

        Text {
          visible: text !== ""
          width: parent.width
          text: {
            if (!root.connected) return "MPD not connected"
            if (!root.hasSong) return "Nothing playing"
            var song = root.service.song
            return String(song.title || root.service.basename(song.file) || "Unknown track")
          }
          color: previewCard.text
          font.family: root.fontFamily
          font.pixelSize: Style.font.subtitle
          font.bold: true
          wrapMode: Text.WordWrap
          maximumLineCount: 2
          elide: Text.ElideRight
        }

        Column {
          width: parent.width
          spacing: Style.space(2)

          Text {
            visible: text !== ""
            width: parent.width
            text: root.hasSong ? String(root.service.song.artist || "") : ""
            color: previewCard.text
            font.family: root.fontFamily
            font.pixelSize: Style.font.bodySmall
            elide: Text.ElideRight
          }

          Text {
            visible: text !== ""
            width: parent.width
            text: {
              if (!root.hasSong) return ""
              var song = root.service.song
              var album = String(song.album || "")
              var date = String(song.date || "")
              if (album === "") return date
              return date === "" ? album : album + "  ·  " + date
            }
            color: previewCard.dim
            font.family: root.fontFamily
            font.pixelSize: Style.font.caption
            elide: Text.ElideRight
          }
        }

        // Progress. Drawn rather than made interactive: this is a hover card,
        // and a pointer that leaves the strip to reach the bar dismisses it
        // before the click lands.
        Column {
          visible: root.hasSong && root.service.duration > 0
          width: parent.width
          spacing: Style.space(4)

          Rectangle {
            width: parent.width
            height: Math.max(2, Style.space(3))
            color: Qt.darker(previewCard.text, 3.0)

            Rectangle {
              width: {
                if (!root.hasSong || root.service.duration <= 0) return 0
                var fraction = root.service.elapsed / root.service.duration
                return Math.round(parent.width * Math.max(0, Math.min(1, fraction)))
              }
              height: parent.height
              color: Color.accent
            }
          }

          Row {
            width: parent.width

            Text {
              id: elapsedText
              text: root.hasSong ? root.service.formatTime(root.service.elapsed) : ""
              color: previewCard.dim
              font.family: root.fontFamily
              font.pixelSize: Style.font.caption
            }

            Item {
              width: parent.width - remainingText.implicitWidth - elapsedText.implicitWidth
              height: 1
            }

            Text {
              id: remainingText
              text: root.hasSong ? "-" + root.service.formatTime(Math.max(0, root.service.duration - root.service.elapsed)) : ""
              color: previewCard.dim
              font.family: root.fontFamily
              font.pixelSize: Style.font.caption
            }
          }
        }

        Text {
          visible: text !== ""
          width: parent.width
          text: {
            if (!root.connected)
              return root.service && root.service.lastError !== ""
                ? root.service.lastError
                : "Waiting for " + (root.service ? root.service.target : "MPD") + "…"
            var bits = []
            if (root.service.queueLength > 0 && root.service.queuePosition >= 0)
              bits.push((root.service.queuePosition + 1) + " of " + root.service.queueLength)
            if (root.service.randomOn) bits.push("random")
            if (root.service.repeatOn) bits.push("repeat")
            if (root.service.singleMode !== "0") bits.push("single")
            if (root.service.consumeOn) bits.push("consume")
            return bits.join("  ·  ")
          }
          color: previewCard.dim
          font.family: root.fontFamily
          font.pixelSize: Style.font.caption
          wrapMode: Text.WordWrap
        }

        Text {
          width: parent.width
          text: "click opens omajam · middle next · right settings"
          color: Qt.darker(previewCard.text, 2.0)
          font.family: root.fontFamily
          font.pixelSize: Style.font.caption
          wrapMode: Text.WordWrap
        }
      }
    }
  }

  // ---------------------------------------------------------- the client
  //
  // Anchored to the label rather than to the gear: it is what clicking the
  // label opens, and it centres on the bar anyway.
  ClientPanel {
    id: clientPanel
    bar: root.bar
    service: root.service
    anchorItem: nowPlaying.visible ? nowPlaying : gearButton
    // The widget owns the window: closing it, and the bar's one-popout-at-a-
    // time coordination, both go through the Panel base.
    owner: root
    open: root.opened
    // Everything the settings tab shows about this widget, and the one thing it
    // cannot do for itself: saving. shell.json has a single writer -- the shell
    // -- and this is the half of the plugin that knows how to ask it.
    widgetSettings: root.settings
    version: root.version
    pythonPresent: root.pythonPresent
    onCloseRequested: root.close()
    onPersistRequested: function(key, value) { root.persist(key, value) }
  }

  // ------------------------------------------------------------ persistence

  property var _saveQueue: []

  function persist(key, value) {
    _saveQueue = _saveQueue.concat([[key, value]])
    drainSaves()
  }

  function drainSaves() {
    if (saveProc.running || !_saveQueue.length) return
    var job = _saveQueue[0]
    _saveQueue = _saveQueue.slice(1)
    saveProc.command = ["omarchy-shell", "shell", "setBarWidget",
      root.moduleName, String(job[0]), JSON.stringify(job[1]), "{}"]
    saveProc.running = true
  }

  Process {
    id: saveProc
    onExited: function(code, status) {
      if (code !== 0) console.warn("omajam: failed to save setting (exit " + code + ")")
      root.drainSaves()
    }
  }

  // The bridge is a python script, and a system without python3 fails in a way
  // that is invisible from the bar: the widget simply never connects. Say so
  // where the connection is configured.
  Process {
    id: pythonProbe
    command: ["bash", "-c", "command -v python3 >/dev/null && echo yes || echo no"]
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: root.pythonPresent = String(text || "").trim() === "yes" ? 1 : 0
    }
  }

  // -1 until the probe has answered, so the warning is not shown in the moment
  // before we know either way.
  property int pythonPresent: -1

}
