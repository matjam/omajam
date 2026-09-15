import Quickshell
import Quickshell.Io
import QtQml

FileView {
  id: root

  property string pluginId: ""
  property var _settings: ({})
  readonly property var settings: _settings
  property bool reading: false
  property bool reloadPending: false
  property Timer trailingReload: Timer {
    interval: 100
    onTriggered: {
      root.reloadSettings()
    }
  }

  property string configPath: Quickshell.env("HOME") + "/.config/omarchy/shell.json"
  path: configPath
  watchChanges: true
  printErrors: false
  preload: true

  function lookupSettings(config, id) {
    if (!config || !id) return null
    var sections = ["left", "center", "right"]
    if (config.bar && config.bar.layout) {
      for (var s = 0; s < sections.length; s++) {
        var list = config.bar.layout[sections[s]]
        if (!Array.isArray(list)) continue
        for (var i = 0; i < list.length; i++) {
          if (list[i] && String(list[i].id) === id) return list[i]
        }
      }
    }
    if (Array.isArray(config.plugins)) {
      for (var j = 0; j < config.plugins.length; j++) {
        if (config.plugins[j] && String(config.plugins[j].id) === id) return config.plugins[j]
      }
    }
    return null
  }

  function reloadSettings() {
    if (reading) {
      reloadPending = true
      return
    }
    reading = true
    reload()
  }

  function finishReload() {
    reading = false
    if (reloadPending) {
      reloadPending = false
      reloadSettings()
    }
  }

  onFileChanged: {
    reloadSettings()
    trailingReload.restart()
  }
  onLoaded: {
    var config = null
    try { config = JSON.parse(text()) } catch (e) {}
    if (config && !Array.isArray(config) && typeof config === "object" && config.version === 1) {
      var found = lookupSettings(config, pluginId)
      _settings = found || ({})
    }
    finishReload()
  }

  onLoadFailed: {
    finishReload()
  }

}
