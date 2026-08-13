pragma ComponentBehavior: Bound

import QtQuick
import qs.Commons

// Everything known about one song, for the browser's third column.
//
// The column exists to show what is behind the cursor, and behind a song there
// is nothing to list -- so it showed nothing at all. What is behind a song is
// the song: its cover, and every tag the server holds for it, which is a good
// deal more than the four columns of a track listing.
//
// Fields are ordered rather than alphabetical: the ones a person reads first,
// then the ones a tagger cares about, then the identifiers, which are shown
// because they are there and dimmed because they are for machines.
Item {
  id: root

  property var song: ({})
  property string artPath: ""
  property bool loading: false

  property string fontFamily: Style.font.family
  property int fontSize: Style.font.bodySmall
  property color foreground: Color.popups.text
  property color accent: Color.accent

  readonly property color dim: Qt.darker(foreground, 1.4)
  readonly property color faint: Qt.rgba(foreground.r, foreground.g, foreground.b, 0.28)

  function value(name) {
    var v = song ? song[name] : undefined
    return v === undefined || v === null ? "" : String(v)
  }

  function formatTime(seconds) {
    var total = Math.floor(Number(seconds) || 0)
    if (!(total > 0)) return ""
    var mins = Math.floor(total / 60)
    var secs = total % 60
    return mins + ":" + (secs < 10 ? "0" + secs : String(secs))
  }

  // "44100:24:2" is three numbers people know by other names.
  function formatAudio(raw) {
    var parts = String(raw || "").split(":")
    if (parts.length < 3) return String(raw || "")
    var rate = Number(parts[0])
    var out = []
    if (rate > 0) out.push((rate % 1000 === 0 ? rate / 1000 : (rate / 1000).toFixed(1)) + " kHz")
    if (parts[1] !== "" && parts[1] !== "f") out.push(parts[1] + " bit")
    else if (parts[1] === "f") out.push("float")
    var channels = Number(parts[2])
    if (channels === 1) out.push("mono")
    else if (channels === 2) out.push("stereo")
    else if (channels > 0) out.push(channels + " channels")
    return out.join("  ·  ")
  }

  function shortDate(raw) {
    // MPD hands back whatever the tag said: a year, or a full timestamp.
    var text = String(raw || "")
    return text.length > 10 ? text.substring(0, 10) : text
  }

  function baseName(path) {
    var name = String(path || "")
    var slash = name.lastIndexOf("/")
    return slash === -1 ? name : name.substring(slash + 1)
  }

  // The rows under the heading, in reading order. Anything absent is dropped
  // rather than shown empty.
  readonly property var rows: {
    var out = []
    var add = function(label, text, faded) {
      if (String(text || "") !== "") out.push({ label: label, text: String(text), faded: !!faded })
    }

    add("Track", value("track") + (value("disc") !== "" ? "   ·   disc " + value("disc") : ""))
    add("Album artist", value("albumartist"))
    add("Composer", value("composer"))
    add("Performer", value("performer"))
    add("Conductor", value("conductor"))
    add("Work", value("work"))
    add("Genre", value("genre"))
    add("Label", value("label"))
    add("Date", shortDate(value("date")))
    if (shortDate(value("originaldate")) !== shortDate(value("date")))
      add("Originally", shortDate(value("originaldate")))
    add("Comment", value("comment"))
    add("Length", formatTime(value("duration") || value("time")))
    add("Audio", formatAudio(value("format")))
    add("File date", shortDate(value("last-modified")))
    add("Added", shortDate(value("added")))

    // Whatever else the server sent and this has not already shown. A library
    // tagged by hand has fields nobody anticipated, and they are the reason
    // someone opens this pane.
    var shown = ["file", "title", "artist", "album", "albumartist", "composer",
                 "performer", "conductor", "work", "genre", "label", "date",
                 "originaldate", "comment", "duration", "time", "format",
                 "last-modified", "added", "track", "disc", "type", "pos", "id"]
    var extras = []
    for (var key in song) {
      if (shown.indexOf(key) !== -1) continue
      if (key.indexOf("musicbrainz") === 0) continue
      if (key.indexOf("sort") !== -1) continue
      extras.push(key)
    }
    extras.sort()
    for (var i = 0; i < extras.length; i++)
      add(extras[i].charAt(0).toUpperCase() + extras[i].substring(1), song[extras[i]])

    // Identifiers last, dimmed: they are for machines, and the pane is for a
    // person deciding whether this is the right recording.
    var ids = []
    for (var mb in song) {
      if (mb.indexOf("musicbrainz") === 0) ids.push(mb)
    }
    ids.sort()
    for (var j = 0; j < ids.length; j++)
      add(ids[j].replace("musicbrainz_", "MB ").replace("id", " id"), song[ids[j]], true)

    return out
  }

  Flickable {
    id: sheet
    anchors.fill: parent
    contentHeight: column.implicitHeight
    clip: true
    boundsBehavior: Flickable.StopAtBounds

    WheelHandler {
      onWheel: function(event) {
        if (event.angleDelta.y === 0) return
        var span = Math.max(0, sheet.contentHeight - sheet.height)
        if (span <= 0) return
        sheet.cancelFlick()
        var step = root.fontSize * 6 * event.angleDelta.y / 120
        sheet.contentY = Math.max(0, Math.min(span, sheet.contentY - step))
      }
    }

    Column {
      id: column
      width: sheet.width
      spacing: Style.space(8)

      // The cover, square, or a frame the same shape when there is none.
      Item {
        width: Math.min(parent.width, Style.space(220))
        height: width

        Image {
          id: cover
          anchors.fill: parent
          visible: status === Image.Ready
          source: root.artPath === "" ? "" : "file://" + root.artPath
          fillMode: Image.PreserveAspectFit
          asynchronous: true
          cache: true
          sourceSize.width: 440
        }

        Rectangle {
          anchors.fill: parent
          visible: !cover.visible
          color: "transparent"
          border.width: Style.normalBorderWidth
          border.color: root.faint
          radius: Style.cornerRadius

          Text {
            anchors.centerIn: parent
            text: root.loading ? "" : "󰝚"
            color: root.faint
            font.family: root.fontFamily
            font.pixelSize: Math.round(parent.height * 0.3)
          }
        }
      }

      Text {
        width: parent.width
        text: root.value("title") !== "" ? root.value("title") : root.baseName(root.value("file"))
        color: root.accent
        font.family: root.fontFamily
        font.pixelSize: Style.font.subtitle
        font.bold: true
        wrapMode: Text.WordWrap
        maximumLineCount: 2
        elide: Text.ElideRight
      }

      Text {
        visible: text !== ""
        width: parent.width
        text: {
          var artist = root.value("artist")
          var album = root.value("album")
          if (artist === "") return album
          return album === "" ? artist : artist + "  ·  " + album
        }
        color: root.foreground
        font.family: root.fontFamily
        font.pixelSize: root.fontSize
        wrapMode: Text.WordWrap
        maximumLineCount: 2
        elide: Text.ElideRight
      }

      Rectangle {
        width: parent.width
        height: Math.max(1, Style.normalBorderWidth)
        color: root.faint
      }

      Repeater {
        model: root.rows

        delegate: Row {
          id: field
          required property var modelData

          width: column.width
          spacing: Style.space(8)

          Text {
            width: Math.round(column.width * 0.34)
            text: field.modelData.label
            color: root.dim
            font.family: root.fontFamily
            font.pixelSize: Style.font.caption
            elide: Text.ElideRight
          }

          Text {
            width: column.width - Math.round(column.width * 0.34) - Style.space(8)
            text: field.modelData.text
            color: field.modelData.faded ? root.faint : root.foreground
            font.family: root.fontFamily
            font.pixelSize: Style.font.caption
            wrapMode: Text.WordWrap
          }
        }
      }

      // The path last, because it is the longest thing here and the least read.
      Text {
        visible: root.value("file") !== ""
        width: parent.width
        text: root.value("file")
        color: root.faint
        font.family: root.fontFamily
        font.pixelSize: Style.font.caption
        wrapMode: Text.WrapAnywhere
      }
    }
  }
}
