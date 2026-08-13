pragma ComponentBehavior: Bound

import QtQuick
import qs.Commons
import qs.Ui
import "Format.js" as Format

// The plugin's own settings, as a tab of the client rather than as a second
// popup off the bar.
//
// Only the plugin's own settings: where the server is, and what the bar shows.
// Both are written to shell.json through the shell, which is the only thing
// allowed to write that file, so they leave here as a request rather than as a
// file operation.
//
// MPD's own playback options are not here. They are in the header, where they
// are one glyph and one click, and on z/x/c/v from anywhere in the window.
Item {
  id: root

  property var service: null
  property bool active: false

  // The widget's saved settings, read by whoever owns this -- the bar widget,
  // which is also the only thing that can save them.
  property var settings: ({})
  property string version: ""
  // -1 until the probe has answered, so the warning is not shown in the moment
  // before we know either way.
  property int pythonPresent: -1

  property string fontFamily: Style.font.family
  property color foreground: Color.popups.text
  property color accent: Color.accent

  readonly property color dim: Qt.darker(foreground, 1.4)

  signal persistRequested(string key, var value)

  // Which group of settings is showing. General first because it holds the two
  // people change: the label and how wide it may be.
  property string section: "general"

  function sectionLabel() {
    if (section === "bar") return "Bar"
    if (section === "server") return "Server"
    return "General"
  }

  // A field with the keyboard must keep it: the client's key handler would
  // otherwise read a hostname with an "n" in it as "next track".
  readonly property bool inputFocused: hostField.activeFocus || portField.field.activeFocus
    || passwordField.activeFocus || formatField.activeFocus

  // Escape hands the keyboard back to the window rather than doing nothing,
  // which is what it would do if a field kept focus while the key handler
  // stepped aside for it.
  function blurInput() {
    hostField.focus = false
    passwordField.focus = false
    formatField.focus = false
    portField.field.focus = false
  }

  function setting(name, fallback) {
    var value = settings ? settings[name] : undefined
    return value === undefined || value === null ? fallback : value
  }

  readonly property string hostSetting: String(setting("host", ""))
  readonly property int portSetting: Math.max(1, Number(setting("port", 6600)) || 6600)
  readonly property string passwordSetting: String(setting("password", ""))
  readonly property string formatSetting: String(setting("format", "[%artist% - ][%title%|%filename%]"))
  readonly property int maxWidthSetting: Math.max(40, Number(setting("maxWidth", 240)) || 240)
  readonly property string overflowSetting: String(setting("overflow", "scroll")) === "elide" ? "elide" : "scroll"
  readonly property bool showControlsSetting: setting("showControls", true) === true
  readonly property string controlsPositionSetting: String(setting("controlsPosition", "right")) === "left" ? "left" : "right"
  readonly property bool showStopSetting: setting("showStop", false) === true
  readonly property bool showStateIconSetting: setting("showStateIcon", true) === true
  readonly property bool showArtSetting: setting("showArt", false) === true
  readonly property bool showSettingsButtonSetting: setting("showSettingsButton", true) === true
  readonly property string whenIdleSetting: String(setting("whenIdle", "icon")) === "hide" ? "hide" : "icon"
  readonly property bool notifyTrackSetting: setting("notifyTrack", false) === true
  readonly property string wheelActionSetting: {
    var value = String(setting("wheelAction", "volume"))
    return ["volume", "seek", "track", "none"].indexOf(value) !== -1 ? value : "volume"
  }

  readonly property bool connected: !!service && service.connected
  // MPD reports a job number while it is reading the library, and nothing at
  // all about its progress -- so this is the whole of what can be shown.
  readonly property bool scanning: connected && service.updatingDb

  // True only while a field holds something not yet committed, so assigning
  // text from the setting cannot arm the write-back and resurrect an old value.
  property bool formatEdited: false
  property bool hostEdited: false
  property bool passwordEdited: false

  // A setting can change from more places than its field: the bar's own
  // settings UI, an edit to shell.json, or this same panel on another monitor.
  // Mirror it back unless the user is part-way through typing something else.
  onFormatSettingChanged: if (!formatEdited) formatField.text = formatSetting
  onHostSettingChanged: if (!hostEdited) hostField.text = hostSetting
  onPasswordSettingChanged: if (!passwordEdited) passwordField.text = passwordSetting

  onActiveChanged: {
    // Closed and reopened should land on General rather than wherever it was
    // left, and the fields should show what is saved rather than a half-typed
    // edit abandoned last time.
    if (!active) {
      section = "general"
      return
    }
    formatEdited = false
    hostEdited = false
    passwordEdited = false
    formatField.text = formatSetting
    hostField.text = hostSetting
    passwordField.text = passwordSetting
  }

  Component.onCompleted: {
    formatField.text = formatSetting
    hostField.text = hostSetting
    passwordField.text = passwordSetting
  }

  function persist(key, value) { persistRequested(key, value) }

  readonly property string connectionLine: {
    if (!service) return "The MPD service is not loaded."
    if (service.connected)
      return "Connected to " + service.target
        + (service.serverVersion === "" ? "" : "  ·  MPD " + service.serverVersion)
    var where = service.target === "" ? "MPD" : service.target
    if (service.lastError !== "") return "Not connected to " + where + " — " + service.lastError
    return "Connecting to " + where + "…"
  }

  // Rendered against whatever is playing, falling back to a fixed sample when
  // nothing is: a preview that says nothing tells the user nothing about the
  // format they are typing.
  readonly property var previewTokens: {
    if (connected && service.hasSong) return service.tokens
    return {
      artist: "Kate Bush", albumartist: "Kate Bush", title: "Hounds of Love",
      album: "Hounds of Love", track: "2", disc: "1", date: "1985",
      genre: "Art Rock", composer: "Kate Bush", performer: "", comment: "",
      name: "",
      file: "Kate Bush/Hounds of Love/02 - Hounds of Love.flac",
      filename: "02 - Hounds of Love", folder: "Kate Bush/Hounds of Love",
      state: "playing", stateicon: "󰐊", elapsed: "1:12", duration: "3:02",
      remaining: "1:50", time: "1:12/3:02", position: "2", length: "12",
      volume: "70", bitrate: "993", audio: "44100:16:2",
      repeat: "", random: "random", single: "", consume: ""
    }
  }

  // --------------------------------------------------------------- layout
  //
  // Three groups behind a switcher rather than one column that has to be
  // scrolled. Each group is controls on the left and the text explaining them
  // on the right, which is what keeps a group to one screen.

  Column {
    anchors.fill: parent
    spacing: Style.space(12)

    ButtonGroup {
      width: parent.width
      options: ["General", "Bar", "Server"]
      value: root.sectionLabel()
      foreground: root.foreground
      fontFamily: root.fontFamily
      onChanged: function(v) { root.section = String(v).toLowerCase() }
    }

    Flickable {
      id: sheet
      width: parent.width
      height: parent.height - y
      contentHeight: groups.implicitHeight
      clip: true
      boundsBehavior: Flickable.StopAtBounds

      // A group should fit, but a short screen is still a screen.
      WheelHandler {
        onWheel: function(event) {
          if (event.angleDelta.y === 0) return
          var span = Math.max(0, sheet.contentHeight - sheet.height)
          if (span <= 0) return
          sheet.cancelFlick()
          var step = Style.font.body * 8 * event.angleDelta.y / 120
          sheet.contentY = Math.max(0, Math.min(span, sheet.contentY - step))
        }
      }

      Item {
        id: groups
        width: sheet.width
        implicitHeight: Math.max(generalGroup.implicitHeight,
                                 barGroup.implicitHeight,
                                 serverGroup.implicitHeight)

        readonly property int columnGap: Style.space(24)
        readonly property int narrow: Math.round((width - columnGap) * 0.55)
        readonly property int wide: width - narrow - columnGap

        // ═════════════════════════════════════════════════════════ general

        Row {
          id: generalGroup
          visible: root.section === "general"
          width: parent.width
          spacing: groups.columnGap

          Column {
            width: groups.narrow
            spacing: Style.space(10)

            PanelSectionHeader {
              text: "LABEL"
              foreground: root.foreground
              fontFamily: root.fontFamily
            }

            TextField {
              id: formatField
              width: parent.width
              foreground: root.foreground
              placeholderText: "[%artist% - ]%title%"
              onTextChanged: {
                if (!activeFocus) return
                root.formatEdited = true
                formatSave.restart()
              }
              onAccepted: {
                formatSave.stop()
                root.formatEdited = false
                root.persist("format", text)
              }
              onEditingFinished: {
                if (!root.formatEdited) return
                formatSave.stop()
                root.formatEdited = false
                if (text !== root.formatSetting) root.persist("format", text)
              }
            }

            // Live, from the field rather than from the saved setting, so the
            // effect of a bracket is visible before committing to it.
            Text {
              width: parent.width
              text: {
                var rendered = Format.render(formatField.text, root.previewTokens)
                return rendered === "" ? "(empty)" : rendered
              }
              color: root.foreground
              font.family: root.fontFamily
              font.pixelSize: Style.font.bodySmall
              elide: Text.ElideRight
            }

            NumberField {
              label: "Label width (pixels)"
              value: root.maxWidthSetting
              from: 40
              to: 1200
              stepSize: 20
              foreground: root.foreground
              fontFamily: root.fontFamily
              onModified: function(v) { root.persist("maxWidth", v) }
            }

            ButtonGroup {
              width: parent.width
              options: ["Scroll", "Elide"]
              value: root.overflowSetting === "elide" ? "Elide" : "Scroll"
              foreground: root.foreground
              fontFamily: root.fontFamily
              onChanged: function(v) { root.persist("overflow", String(v).toLowerCase()) }
            }

            Toggle {
              width: parent.width
              label: "Notify on track change"
              description: "A desktop notification with the cover, through the shell's own notifications."
              checked: root.notifyTrackSetting
              foreground: root.foreground
              fontFamily: root.fontFamily
              onClicked: root.persist("notifyTrack", !root.notifyTrackSetting)
            }
          }

          Column {
            width: groups.wide
            spacing: Style.space(10)

            PanelSectionHeader {
              text: "FORMAT"
              foreground: root.foreground
              fontFamily: root.fontFamily
            }

            Text {
              width: parent.width
              text: "%tag% substitutes · [ ] drops the whole group when a tag inside is missing · [a|b] takes the first that resolves"
              color: root.dim
              font.family: root.fontFamily
              font.pixelSize: Style.font.caption
              wrapMode: Text.WordWrap
            }

            Text {
              width: parent.width
              text: Format.tagNames().join(" · ")
              color: Qt.darker(root.foreground, 1.8)
              font.family: root.fontFamily
              font.pixelSize: Style.font.caption
              wrapMode: Text.WordWrap
            }
          }
        }

        // The label is the one setting whose effect is on the bar rather than
        // in this panel, and writing a format is a fiddling exercise: the bar
        // should follow along while it is typed. Saved shortly after typing
        // stops. The connection fields are deliberately not treated this way,
        // since each save there costs a reconnect.
        Timer {
          id: formatSave
          interval: 500
          repeat: false
          onTriggered: {
            if (!root.formatEdited) return
            // Never from empty. Clearing the field is a step on the way to
            // typing a new format, and the bar losing its label because typing
            // paused is not what saving-as-you-type was for. Enter and moving
            // focus away still commit it, since those are decisions.
            if (formatField.text === "") return
            root.persist("format", formatField.text)
          }
        }

        // ═════════════════════════════════════════════════════════════ bar

        Row {
          id: barGroup
          visible: root.section === "bar"
          width: parent.width
          spacing: groups.columnGap

          Column {
            width: groups.narrow
            spacing: Style.space(10)

            PanelSectionHeader {
              text: "PARTS"
              foreground: root.foreground
              fontFamily: root.fontFamily
            }

            Toggle {
              width: parent.width
              label: "Playback controls"
              description: "Previous, play/pause and next in the bar."
              checked: root.showControlsSetting
              foreground: root.foreground
              fontFamily: root.fontFamily
              onClicked: root.persist("showControls", !root.showControlsSetting)
            }

            ButtonGroup {
              visible: root.showControlsSetting
              width: parent.width
              options: ["Before label", "After label"]
              value: root.controlsPositionSetting === "left" ? "Before label" : "After label"
              foreground: root.foreground
              fontFamily: root.fontFamily
              onChanged: function(v) {
                root.persist("controlsPosition", String(v).indexOf("Before") === 0 ? "left" : "right")
              }
            }

            Toggle {
              visible: root.showControlsSetting
              width: parent.width
              label: "Stop button"
              description: "A fourth button. Play still resumes where stop left off."
              checked: root.showStopSetting
              foreground: root.foreground
              fontFamily: root.fontFamily
              onClicked: root.persist("showStop", !root.showStopSetting)
            }

            Toggle {
              width: parent.width
              label: "Play state glyph"
              description: "The ▶ / ⏸ ahead of the label."
              checked: root.showStateIconSetting
              foreground: root.foreground
              fontFamily: root.fontFamily
              onClicked: root.persist("showStateIcon", !root.showStateIconSetting)
            }

            Toggle {
              width: parent.width
              label: "Cover thumbnail"
              description: "A small cover in the bar as well as in the hover card."
              checked: root.showArtSetting
              foreground: root.foreground
              fontFamily: root.fontFamily
              onClicked: root.persist("showArt", !root.showArtSetting)
            }

            Toggle {
              width: parent.width
              label: "Settings button"
              description: "The cog beside the label, which opens this tab."
              checked: root.showSettingsButtonSetting
              foreground: root.foreground
              fontFamily: root.fontFamily
              onClicked: root.persist("showSettingsButton", !root.showSettingsButtonSetting)
            }
          }

          Column {
            width: groups.wide
            spacing: Style.space(10)

            PanelSectionHeader {
              text: "WHEN NOTHING IS PLAYING"
              foreground: root.foreground
              fontFamily: root.fontFamily
            }

            ButtonGroup {
              width: parent.width
              options: ["Show icon", "Hide widget"]
              value: root.whenIdleSetting === "hide" ? "Hide widget" : "Show icon"
              foreground: root.foreground
              fontFamily: root.fontFamily
              onChanged: function(v) {
                root.persist("whenIdle", String(v).indexOf("Hide") === 0 ? "hide" : "icon")
              }
            }

            Text {
              visible: root.whenIdleSetting === "hide"
              width: parent.width
              text: "The whole widget goes when nothing is playing, cog included. `omarchy-shell matjam.omajam client` brings this window back."
              color: root.dim
              font.family: root.fontFamily
              font.pixelSize: Style.font.caption
              wrapMode: Text.WordWrap
            }

            PanelSectionHeader {
              text: "SCROLL WHEEL"
              foreground: root.foreground
              fontFamily: root.fontFamily
            }

            ButtonGroup {
              width: parent.width
              options: ["Volume", "Seek", "Track", "Nothing"]
              value: {
                if (root.wheelActionSetting === "seek") return "Seek"
                if (root.wheelActionSetting === "track") return "Track"
                if (root.wheelActionSetting === "none") return "Nothing"
                return "Volume"
              }
              foreground: root.foreground
              fontFamily: root.fontFamily
              onChanged: function(v) {
                var picked = String(v).toLowerCase()
                root.persist("wheelAction", picked === "nothing" ? "none" : picked)
              }
            }

            Text {
              width: parent.width
              text: "Over the label in the bar, not over this window."
              color: root.dim
              font.family: root.fontFamily
              font.pixelSize: Style.font.caption
              wrapMode: Text.WordWrap
            }
          }
        }

        // ══════════════════════════════════════════════════════════ server

        Row {
          id: serverGroup
          visible: root.section === "server"
          width: parent.width
          spacing: groups.columnGap

          Column {
            width: groups.narrow
            spacing: Style.space(10)

            PanelSectionHeader {
              text: "CONNECTION"
              foreground: root.foreground
              fontFamily: root.fontFamily
            }

            Text {
              width: parent.width
              text: root.connectionLine
              color: root.connected ? root.dim : Color.urgent
              font.family: root.fontFamily
              font.pixelSize: Style.font.caption
              wrapMode: Text.WordWrap
            }

            Text {
              visible: root.pythonPresent === 0
              width: parent.width
              text: "python3 is not installed — run: sudo pacman -S python"
              color: Color.urgent
              font.family: root.fontFamily
              font.pixelSize: Style.font.caption
              wrapMode: Text.WordWrap
            }

            TextField {
              id: hostField
              width: parent.width
              foreground: root.foreground
              placeholderText: "127.0.0.1, or /run/mpd/socket"
              onTextChanged: if (activeFocus) root.hostEdited = true
              onAccepted: {
                root.hostEdited = false
                root.persist("host", text.trim())
              }
              onEditingFinished: {
                if (!root.hostEdited) return
                root.hostEdited = false
                if (text.trim() !== root.hostSetting) root.persist("host", text.trim())
              }
            }

            NumberField {
              id: portField
              label: "Port"
              value: root.portSetting
              from: 1
              to: 65535
              stepSize: 1
              foreground: root.foreground
              fontFamily: root.fontFamily
              onModified: function(v) { root.persist("port", v) }
            }

            TextField {
              id: passwordField
              width: parent.width
              foreground: root.foreground
              password: true
              placeholderText: "Password (only if MPD asks for one)"
              onTextChanged: if (activeFocus) root.passwordEdited = true
              onAccepted: {
                root.passwordEdited = false
                root.persist("password", text)
              }
              onEditingFinished: {
                if (!root.passwordEdited) return
                root.passwordEdited = false
                if (text !== root.passwordSetting) root.persist("password", text)
              }
            }

            Flow {
              width: parent.width
              spacing: Style.space(8)

              Button {
                text: "Reconnect"
                bordered: true
                foreground: root.foreground
                fontFamily: root.fontFamily
                onClicked: if (root.service) root.service.reconnect()
              }

              Button {
                text: root.scanning ? "Scanning…" : "Update database"
                bordered: true
                enabled: root.connected && !root.scanning
                opacity: enabled ? 1.0 : 0.4
                foreground: root.foreground
                fontFamily: root.fontFamily
                onClicked: if (root.service) root.service.updateDatabase()
              }

              Button {
                text: "Rescan everything"
                bordered: true
                enabled: root.connected && !root.scanning
                opacity: enabled ? 1.0 : 0.4
                foreground: root.foreground
                fontFamily: root.fontFamily
                onClicked: if (root.service) root.service.rescanDatabase()
              }
            }
          }

          Column {
            width: groups.wide
            spacing: Style.space(10)

            PanelSectionHeader {
              text: "NOTES"
              foreground: root.foreground
              fontFamily: root.fontFamily
            }

            Text {
              width: parent.width
              text: "Empty follows $MPD_HOST, then 127.0.0.1. A path or an @name is a unix socket, and the port is ignored for those."
              color: root.dim
              font.family: root.fontFamily
              font.pixelSize: Style.font.caption
              wrapMode: Text.WordWrap
            }

            Text {
              visible: root.passwordSetting !== ""
              width: parent.width
              text: "Stored as plain text in shell.json, like every other shell setting. Leave it empty and set $MPD_HOST to password@host to keep it in your environment."
              color: root.dim
              font.family: root.fontFamily
              font.pixelSize: Style.font.caption
              wrapMode: Text.WordWrap
            }

            Text {
              width: parent.width
              text: root.scanning
                ? "MPD is reading the library. It says nothing about how far along it is, only that it is still going."
                : "Update reads the files whose timestamps changed, after adding a record. Rescan re-reads every file, for tags edited in place. u and U do the same from anywhere in this window."
              color: root.dim
              font.family: root.fontFamily
              font.pixelSize: Style.font.caption
              wrapMode: Text.WordWrap
            }

            Text {
              visible: root.version !== ""
              width: parent.width
              text: "omajam v" + root.version
              color: Qt.darker(root.foreground, 1.9)
              font.family: root.fontFamily
              font.pixelSize: Style.font.caption
            }
          }
        }
      }
    }
  }
}
