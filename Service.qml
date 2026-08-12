import QtQuick
import Quickshell.Io

// The plugin's connection to MPD, held once for the whole shell.
//
// MPD is a server somewhere -- another process, often another machine -- and
// it is reached through a child process (bin/omajam-mpd; see the comment at the
// top of that file for why a bridge exists at all). Everything below is a view
// of what that bridge reports and a way to send it commands.
//
// Two kinds of traffic go over it. Playback state is pushed: the bridge sits in
// MPD's `idle` and announces what changed, so `song`, `elapsed` and the rest
// are always current without anything here polling. Browsing is pulled:
// `request()` asks a question, and an answer arrives at a callback some
// milliseconds later. The queue is the one thing that is both -- pulled, but
// re-pulled by itself whenever the server says its version changed.
//
// The bar widget is instantiated per monitor, so none of this can live there: a
// three-monitor desktop would open three MPD connections and each button press
// would race the other two. Every widget instance reads this one service back
// through `shell.serviceFor()`.
Item {
  id: root

  // Injected by the shell's service loader (see shell.qml ensureService).
  property var shell: null
  property var manifest: null

  readonly property string pluginId: (manifest && manifest.id) || "matjam.omajam"
  readonly property string sourceDir: (manifest && manifest.__sourceDir) ? String(manifest.__sourceDir) : ""

  // ------------------------------------------------------------- settings
  //
  // Read out of the bar layout entry the widget writes through setBarWidget,
  // exactly as the widget reads them, so a saved change reaches the connection
  // without a shell restart.
  readonly property var settings: lookupSettings(shell ? shell.shellConfig : null, pluginId)

  function setting(name, fallback) {
    var value = settings ? settings[name] : undefined
    return value === undefined || value === null ? fallback : value
  }

  function lookupSettings(config, id) {
    if (!config || !id) return ({})
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
    return ({})
  }

  readonly property string host: String(setting("host", "")).trim()
  readonly property int port: Math.max(0, Number(setting("port", 6600)) || 0)
  readonly property string password: String(setting("password", ""))
  readonly property bool notifyTrack: setting("notifyTrack", false) === true

  // One string rather than three change handlers: a host and port edited in
  // the same breath should cost one reconnect, and QML collapses the two
  // property writes into a single change of this.
  readonly property string connectionKey: JSON.stringify([host, port, password])

  onConnectionKeyChanged: sendConfig()

  // ================================================================= state

  property bool connected: false
  property string serverVersion: ""
  property string target: ""
  property string lastError: ""

  property var status: ({})
  property var song: ({})
  property string artPath: ""
  property string artUri: ""

  readonly property string playbackState: String(status.state || "stop")
  readonly property bool isPlaying: playbackState === "play"
  readonly property bool isPaused: playbackState === "pause"
  readonly property string songFile: String(song.file || "")
  readonly property bool hasSong: songFile !== ""

  // -1 means "this MPD has no mixer", which is a real state and not silence.
  readonly property int volume: status.volume === undefined ? -1 : Number(status.volume)
  readonly property real duration: Number(status.duration || song.duration || song.time || 0) || 0

  readonly property bool repeatOn: String(status.repeat || "0") === "1"
  readonly property bool randomOn: String(status.random || "0") === "1"
  readonly property bool consumeOn: String(status.consume || "0") === "1"
  readonly property string singleMode: String(status.single || "0")

  readonly property int queuePosition: status.song === undefined ? -1 : Number(status.song)
  readonly property int queueLength: Number(status.playlistlength || 0) || 0
  readonly property int currentSongId: status.songid === undefined ? -1 : Number(status.songid)
  readonly property bool updatingDb: status.updating_db !== undefined

  // Bumped every time MPD says the library changed. Anything showing the
  // library -- every browser pane -- watches this and refetches, because after
  // a scan the rows on screen describe a database that no longer exists.
  //
  // Driven by MPD's `database` idle event rather than by watching updating_db
  // fall back to nothing: a scan of a handful of files can start and finish
  // between two status reads, and the flag would never be seen set. The event
  // is also the more honest signal, since MPD only sends it when the scan
  // actually found a change.
  property int databaseVersion: 0

  readonly property string bitrate: String(status.bitrate || "")
  readonly property string audioFormat: String(status.audio || "")

  // ------------------------------------------------------------------ art
  //
  // A ready-to-use image source: a file the bridge wrote into the cache, or
  // nothing at all for a track whose album has no cover anywhere.
  readonly property string artSource: {
    if (artPath === "") return ""
    // The art event and the state event arrive separately, so a fast skip can
    // briefly pair the previous cover with the new title. Showing nothing is
    // better than showing the wrong record.
    if (artUri !== String(song.file || "")) return ""
    return "file://" + artPath
  }

  // ------------------------------------------------------- elapsed clock
  //
  // MPD reports elapsed only when something changes, so the reported value is
  // treated as a reading taken at `elapsedAt` and carried forward locally.
  // Every fresh reading resets the pair, so drift cannot accumulate.
  property real reportedElapsed: 0
  property real elapsedAt: 0
  property real nowMs: 0

  function seedElapsed(seconds) {
    reportedElapsed = Math.max(0, Number(seconds) || 0)
    elapsedAt = Date.now()
    nowMs = elapsedAt
  }

  readonly property real elapsed: {
    if (!hasSong) return 0
    if (!isPlaying) return reportedElapsed
    var carried = reportedElapsed + Math.max(0, nowMs - elapsedAt) / 1000
    return duration > 0 ? Math.min(duration, carried) : carried
  }

  Timer {
    interval: 1000
    repeat: true
    running: root.isPlaying
    onTriggered: root.nowMs = Date.now()
  }

  // ========================================================= track toasts
  //
  // A desktop notification rather than a window of this plugin's own: the shell
  // is the notification server, so this arrives styled like everything else,
  // lands where the user put their notifications, and obeys do-not-disturb.
  //
  // `lastToastFile` doubles as the arm: it is set without notifying for the
  // first song seen on a connection, so restarting the shell mid-album does not
  // announce what was already playing.
  property string lastToastFile: ""
  property int lastToastId: 0

  onSongFileChanged: {
    if (songFile === "" || !connected || !notifyTrack) {
      lastToastFile = songFile
      return
    }
    var first = lastToastFile === ""
    lastToastFile = songFile
    if (first || !isPlaying) return
    // The art arrives in its own event, usually a moment after the song does.
    // Waiting for it costs a beat and buys a cover on the toast.
    toastDelay.restart()
  }

  Timer {
    id: toastDelay
    interval: 700
    repeat: false
    onTriggered: root.sendToast()
  }

  function sendToast() {
    if (!notifyTrack || !isPlaying || songFile === "") return
    // One at a time. Tracks are minutes apart; a toast still being written is a
    // reason to skip rather than to queue.
    if (toastProc.running) return

    var title = songTitle(song)
    var parts = []
    if (String(song.artist || "") !== "") parts.push(String(song.artist))
    if (String(song.album || "") !== "") parts.push(String(song.album))

    var command = ["notify-send", "-a", "omajam", "-p", "-t", "5000",
                   "-h", "string:x-canonical-private-synchronous:omajam"]
    // Replacing the previous toast rather than stacking one per track.
    if (lastToastId > 0) command = command.concat(["-r", String(lastToastId)])
    if (artPath !== "" && artUri === songFile)
      command = command.concat(["-i", artPath, "-h", "string:image-path:file://" + artPath])
    command = command.concat([title === "" ? "Now playing" : title, parts.join("  ·  ")])

    toastProc.command = command
    toastProc.running = true
  }

  Process {
    id: toastProc
    // notify-send -p prints the id it was given, which is what makes the next
    // toast replace this one instead of piling up beneath it.
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: {
        var id = parseInt(String(text || "").trim())
        if (id > 0) root.lastToastId = id
      }
    }
  }

  // ============================================================ the queue
  //
  // Pulled rather than pushed -- MPD's idle says the queue changed, not what it
  // now is -- but pulled by this service rather than by the panel, because the
  // bar's label wants `%position%/%length%` whether or not any panel is open,
  // and because two panels on two monitors should not fetch it twice.
  //
  // `status.playlist` is the queue's version number. Every change to the queue
  // increments it, which makes it exactly the right thing to watch.
  property var queue: []
  property bool queueLoading: false

  readonly property string queueVersion: String(status.playlist === undefined ? "" : status.playlist)

  onQueueVersionChanged: refreshQueue()

  function refreshQueue() {
    if (!connected) {
      queue = []
      return
    }
    queueLoading = true
    request("queue", { channel: "queue" }, function(rows) {
      root.queueLoading = false
      root.queue = rows
    })
  }

  // Where a song id sits in the queue, or -1. The panel follows the playing
  // song with this, and a queue of ten thousand makes the loop worth keeping
  // out of a binding that re-runs on every clock tick.
  function queueIndexOfId(id) {
    var wanted = Number(id)
    if (!(wanted >= 0)) return -1
    for (var i = 0; i < queue.length; i++) {
      if (Number(queue[i].id) === wanted) return i
    }
    return -1
  }

  // ============================================================== queries
  //
  // One question, one answer, on the bridge's own connection. The handler is
  // called with (rows, error, event) -- rows always an array, error "" unless
  // the server refused.
  //
  // `channel` names a stream of questions where only the newest matters: a
  // request with a channel supersedes any earlier unanswered one with the same
  // channel, which is what makes typing into the search box cost one query
  // rather than one per keystroke. The bridge drops the stale ones; this drops
  // any answer that arrives for one anyway.
  property int nextRequestId: 1
  property var pendingRequests: ({})
  property var channelRequests: ({})

  function request(kind, args, handler) {
    var payload = ({})
    if (args) {
      for (var key in args) payload[key] = args[key]
    }
    var id = nextRequestId++
    payload.id = id
    payload.kind = String(kind)

    if (!bridge.running || !connected) {
      // Answer anyway, and with the truth: a pane that never hears back has no
      // way to stop saying "loading…".
      if (handler) Qt.callLater(function() { handler([], "not connected", ({})) })
      return id
    }

    pendingRequests[id] = handler
    if (payload.channel) channelRequests[String(payload.channel)] = id
    send("query " + JSON.stringify(payload))
    return id
  }

  function deliver(event) {
    var id = Number(event.id)
    var handler = pendingRequests[id]
    if (handler === undefined) return
    delete pendingRequests[id]
    var channel = String(event.channel || "")
    if (channel !== "") {
      if (channelRequests[channel] !== id) return  // superseded while in flight
      delete channelRequests[channel]
    }
    if (typeof handler === "function")
      handler(Array.isArray(event.rows) ? event.rows : [], String(event.error || ""), event)
  }

  // Nothing in flight survives a reconnection: the answers were about a server
  // this no longer has, and a pane waiting forever is worse than an empty one.
  function failPending(reason) {
    var handlers = pendingRequests
    pendingRequests = ({})
    channelRequests = ({})
    for (var id in handlers) {
      var handler = handlers[id]
      if (typeof handler === "function") handler([], reason, ({}))
    }
  }

  // ------------------------------------------------------------ commands

  function send(line) {
    if (!bridge.running) return
    bridge.write(String(line) + "\n")
  }

  function sendConfig() {
    // Over stdin rather than argv: a password in a command line is visible to
    // every process on the machine through ps.
    send("config " + JSON.stringify({ host: host, port: port, password: password }))
  }

  function toggle() { send("toggle") }
  function play() { send("play") }
  function pause() { send("pause") }
  function stop() { send("stop") }
  function next() { send("next") }
  function previous() { send("prev") }

  function seek(seconds) { send("seek " + Math.max(0, Number(seconds) || 0)) }

  function setVolume(value) {
    send("volume " + Math.round(Math.max(0, Math.min(100, Number(value) || 0))))
  }

  function nudgeVolume(delta) {
    if (volume < 0) return
    setVolume(volume + delta)
  }

  function setOption(name, value) { send("setopt " + name + " " + value) }

  function toggleOption(name) {
    if (name === "repeat") setOption("repeat", repeatOn ? "0" : "1")
    else if (name === "random") setOption("random", randomOn ? "0" : "1")
    else if (name === "consume") setOption("consume", consumeOn ? "0" : "1")
    // single cycles through MPD's third value: stop after this track, once.
    else if (name === "single") setOption("single", singleMode === "0" ? "1" : (singleMode === "1" ? "oneshot" : "0"))
  }

  function updateDatabase() { send("update") }
  function rescanDatabase() { send("rescan") }
  function refresh() { send("refresh") }

  // ------------------------------------------------- queue and playlists

  function command(op, args) {
    var payload = ({})
    if (args) {
      for (var key in args) payload[key] = args[key]
    }
    payload.op = String(op)
    send("cmd " + JSON.stringify(payload))
  }

  function playId(id) { command("playid", { id: Number(id) }) }
  function playPosition(pos) { command("playpos", { pos: Number(pos) }) }
  function addUri(uri) { command("add", { uri: String(uri) }) }
  function addAndPlay(uri) { command("addplay", { uri: String(uri) }) }
  function insertUri(uri) { command("insert", { uri: String(uri) }) }
  function addFilter(filter) { command("findadd", { filter: filter }) }
  function addFilterAndPlay(filter) { command("findplay", { filter: filter }) }
  function removeId(id) { command("remove", { id: Number(id) }) }
  function moveSong(from, to) { command("move", { from: Number(from), to: Number(to) }) }
  function clearQueue() { command("clear") }
  function shuffleQueue() { command("shuffle") }
  function cropQueue() { command("crop") }
  function loadPlaylist(name) { command("loadplaylist", { name: String(name) }) }
  function savePlaylist(name) { command("saveplaylist", { name: String(name) }) }
  function removePlaylist(name) { command("rmplaylist", { name: String(name) }) }
  function renamePlaylist(name, to) { command("renameplaylist", { name: String(name), to: String(to) }) }
  function playlistAdd(name, uri) { command("playlistadd", { name: String(name), uri: String(uri) }) }

  // Full restart rather than a reconnect command: the panel's button is for
  // when something is wrong, and the wider the reset the more it can fix.
  function reconnect() {
    if (bridge.running) bridge.running = false
    restartTimer.restart()
  }

  readonly property bool bridgeRunning: bridge.running

  // ------------------------------------------------------------- helpers

  function formatTime(seconds) {
    var total = Math.max(0, Math.floor(Number(seconds) || 0))
    var mins = Math.floor(total / 60)
    var secs = total % 60
    var pad = function(n) { return n < 10 ? "0" + n : String(n) }
    if (mins < 60) return mins + ":" + pad(secs)
    return Math.floor(mins / 60) + ":" + pad(mins % 60) + ":" + pad(secs)
  }

  function basename(path) {
    var name = String(path || "")
    var slash = name.lastIndexOf("/")
    if (slash !== -1) name = name.substring(slash + 1)
    var dot = name.lastIndexOf(".")
    return dot > 0 ? name.substring(0, dot) : name
  }

  function dirname(path) {
    var name = String(path || "")
    var slash = name.lastIndexOf("/")
    return slash === -1 ? "" : name.substring(0, slash)
  }

  // A song's length in seconds, whichever of MPD's two spellings it carries.
  function songDuration(entry) {
    if (!entry) return 0
    return Number(entry.duration || entry.time || 0) || 0
  }

  // What a song row is called when it has no title, which is most of an
  // untagged library.
  function songTitle(entry) {
    if (!entry) return ""
    var title = String(entry.title || "")
    return title !== "" ? title : basename(entry.file)
  }

  readonly property string stateIcon: isPlaying ? "󰐊" : (isPaused ? "󰏤" : "󰓛")

  // ------------------------------------------------------------- tokens
  //
  // Everything the label format can name. Rebuilt on every state change and on
  // every tick of the clock above, which is what keeps %elapsed% moving.
  readonly property var tokens: {
    var s = song
    var out = {
      artist: s.artist || "",
      albumartist: s.albumartist || "",
      title: s.title || "",
      album: s.album || "",
      track: s.track || "",
      disc: s.disc || "",
      date: s.date || "",
      genre: s.genre || "",
      composer: s.composer || "",
      performer: s.performer || "",
      comment: s.comment || "",
      // `name` is the stream name of an internet radio station, which is the
      // only title many of them carry.
      name: s.name || "",
      file: s.file || "",
      filename: basename(s.file),
      folder: dirname(s.file),
      state: isPlaying ? "playing" : (isPaused ? "paused" : "stopped"),
      stateicon: stateIcon,
      elapsed: hasSong ? formatTime(elapsed) : "",
      duration: duration > 0 ? formatTime(duration) : "",
      remaining: duration > 0 ? formatTime(Math.max(0, duration - elapsed)) : "",
      position: queuePosition >= 0 ? String(queuePosition + 1) : "",
      length: queueLength > 0 ? String(queueLength) : "",
      volume: volume >= 0 ? String(volume) : "",
      bitrate: bitrate,
      audio: audioFormat,
      repeat: repeatOn ? "repeat" : "",
      random: randomOn ? "random" : "",
      single: singleMode !== "0" ? "single" : "",
      consume: consumeOn ? "consume" : ""
    }
    out.time = out.duration === "" ? out.elapsed : out.elapsed + "/" + out.duration
    return out
  }

  // -------------------------------------------------------------- bridge

  function handle(line) {
    var text = String(line || "").trim()
    if (text === "") return
    var event = null
    try {
      event = JSON.parse(text)
    } catch (e) {
      console.warn("omajam: unparsable line from the bridge: " + text)
      return
    }
    if (!event || !event.event) return

    if (event.event === "state") {
      root.status = event.status || ({})
      root.song = event.song || ({})
      root.seedElapsed(Number(root.status.elapsed || 0) || 0)
    } else if (event.event === "database") {
      root.databaseVersion++
    } else if (event.event === "result") {
      root.deliver(event)
    } else if (event.event === "art") {
      root.artUri = String(event.uri || "")
      root.artPath = String(event.path || "")
    } else if (event.event === "connected") {
      // Where and what before whether: `connected` is the property everything
      // watches, and anything reacting to it reads the other two.
      root.serverVersion = String(event.version || "")
      root.target = String(event.target || "")
      root.lastError = ""
      root.connected = true
      root.refreshQueue()
    } else if (event.event === "disconnected") {
      root.connected = false
      root.serverVersion = ""
      root.status = ({})
      root.song = ({})
      root.artPath = ""
      root.artUri = ""
      root.queue = []
      root.queueLoading = false
      root.failPending(String(event.error || "disconnected"))
      if (event.target) root.target = String(event.target)
      root.lastError = String(event.error || "")
    } else if (event.event === "ack") {
      // A rejected command, not a broken connection: the panel shows it and
      // the next successful command clears it.
      root.lastError = String(event.error || "")
    }
  }

  // Where the bridge lives. Empty until the shell has injected the manifest,
  // which is why nothing below starts on a binding.
  readonly property string bridgePath: sourceDir === "" ? "" : sourceDir + "/bin/omajam-mpd"

  onBridgePathChanged: Qt.callLater(syncBridge)
  Component.onCompleted: Qt.callLater(syncBridge)

  // `running` is set here rather than bound, and after the bindings have
  // settled. Bound, it could go true in the same pass that `command` was still
  // the empty-sourceDir spelling of the path, and the shell would spawn
  // python3 on /bin/omajam-mpd -- which is nowhere.
  function syncBridge() {
    bridge.running = bridgePath !== ""
  }

  Process {
    id: bridge
    running: false
    // Invoked through the interpreter rather than the shebang so a checkout
    // that lost its executable bit still works.
    command: ["python3", root.bridgePath]
    stdinEnabled: true

    // The bridge holds no settings of its own; it is told them once it is
    // there to listen.
    onStarted: root.sendConfig()

    // `exitStatus` rather than `status`: the parameter would otherwise shadow
    // this service's own `status` inside the handler.
    onExited: function(code, exitStatus) {
      root.connected = false
      root.status = ({})
      root.song = ({})
      root.queue = []
      root.failPending("the MPD bridge exited")
      if (root.lastError === "")
        root.lastError = "the MPD bridge exited (code " + code + ")"
      restartTimer.restart()
    }

    stdout: SplitParser {
      splitMarker: "\n"
      onRead: function(line) { root.handle(line) }
    }

    // The bridge only writes here when something went wrong in a way it could
    // not report as an event -- a python traceback, say. Losing that to a
    // closed pipe would turn a fixable problem into a silent one.
    stderr: SplitParser {
      splitMarker: "\n"
      onRead: function(line) {
        var text = String(line || "").trim()
        if (text !== "") console.warn("omajam: " + text)
      }
    }
  }

  Timer {
    id: restartTimer
    interval: 2000
    repeat: false
    onTriggered: if (!bridge.running && root.bridgePath !== "") bridge.running = true
  }

  // Reachable from a keybind or a script:
  //   omarchy-shell -q mpd toggle
  //   omarchy-shell mpd status
  IpcHandler {
    target: "mpd"

    function toggle(): string { root.toggle(); return "ok" }
    function play(): string { root.play(); return "ok" }
    function pause(): string { root.pause(); return "ok" }
    function stop(): string { root.stop(); return "ok" }
    function next(): string { root.next(); return "ok" }
    function previous(): string { root.previous(); return "ok" }
    function prev(): string { root.previous(); return "ok" }

    function seek(seconds: string): string {
      root.seek(Number(seconds))
      return "ok"
    }

    function volume(level: string): string {
      if (String(level).trim() === "") return String(root.volume)
      var text = String(level).trim()
      // A leading sign is a nudge, a bare number an absolute level -- the same
      // spelling `wpctl` and `mpc volume` use.
      if (text.charAt(0) === "+" || text.charAt(0) === "-") root.nudgeVolume(Number(text))
      else root.setVolume(Number(text))
      return "ok"
    }

    function option(name: string): string { root.toggleOption(String(name)); return "ok" }
    function update(): string { root.updateDatabase(); return "ok" }
    function rescan(): string { root.rescanDatabase(); return "ok" }
    function reconnect(): string { root.reconnect(); return "ok" }

    function clear(): string { root.clearQueue(); return "ok" }
    function shuffle(): string { root.shuffleQueue(); return "ok" }
    function crop(): string { root.cropQueue(); return "ok" }
    function add(uri: string): string { root.addUri(String(uri)); return "ok" }
    function load(name: string): string { root.loadPlaylist(String(name)); return "ok" }
    function save(name: string): string { root.savePlaylist(String(name)); return "ok" }

    function queue(): string { return JSON.stringify(root.queue) }

    function status(): string {
      return JSON.stringify({
        connected: root.connected,
        target: root.target,
        version: root.serverVersion,
        error: root.lastError,
        state: root.playbackState,
        volume: root.volume,
        elapsed: root.elapsed,
        duration: root.duration,
        song: root.song,
        art: root.artSource,
        repeat: root.repeatOn,
        random: root.randomOn,
        single: root.singleMode,
        consume: root.consumeOn,
        queue: { position: root.queuePosition, length: root.queueLength }
      })
    }
  }

}
