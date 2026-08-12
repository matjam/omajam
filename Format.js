.pragma library

// The bar label's format language, in mpc's dialect so a format copied out of
// an .mpdconf or a status-bar script mostly works here unchanged.
//
//   %tag%        substituted, empty when the tag is missing
//   [ ... ]      dropped entirely unless every %tag% inside it resolved
//   [ a | b ]    alternatives; the first branch that resolves wins
//   %%           a literal percent, \x a literal x
//
// The bracket rule is the whole point: "[%artist% - ]%title%" loses the dash
// along with the artist rather than leaving a title that starts with one.
//
// `|` splits alternatives only inside brackets. At the top level it is an
// ordinary character, because a format like "%artist% | %title%" is a
// separator someone typed on purpose.

// A format containing %elapsed% is re-rendered every second, and the panel
// renders a second one -- the field's live text -- alongside it while it is
// open. A handful of entries covers both without a single-slot cache thrashing
// between them; past that it is a new set of formats and the old ones go.
var _cache = ({})
var _cacheSize = 0

function parse(text) {
  var source = String(text === undefined || text === null ? "" : text)
  // Prefixed, so a format of "toString" or "constructor" looks up a key of
  // ours rather than something inherited from Object.prototype.
  var key = "f" + source
  var hit = _cache[key]
  if (hit !== undefined) return hit
  if (_cacheSize >= 8) {
    _cache = ({})
    _cacheSize = 0
  }
  var parsed = _parse(source, 0, 0).alts
  _cache[key] = parsed
  _cacheSize += 1
  return parsed
}

// Returns { alts: [[node, ...], ...], i: index of the terminator }.
// Nodes are { t: "l", v } literal, { t: "t", v } tag, { t: "g", alts } group.
function _parse(source, i, depth) {
  var alts = []
  var nodes = []
  var literal = ""

  function flush() {
    if (literal !== "") {
      nodes.push({ t: "l", v: literal })
      literal = ""
    }
  }

  while (i < source.length) {
    var ch = source.charAt(i)

    if (ch === "\\" && i + 1 < source.length) {
      literal += source.charAt(i + 1)
      i += 2
      continue
    }

    if (ch === "%") {
      if (source.charAt(i + 1) === "%") {
        literal += "%"
        i += 2
        continue
      }
      var end = source.indexOf("%", i + 1)
      // An unterminated %: the user is mid-type. Show it as typed rather than
      // swallowing the rest of the format.
      if (end === -1) {
        literal += "%"
        i += 1
        continue
      }
      flush()
      nodes.push({ t: "t", v: source.substring(i + 1, end).toLowerCase().trim() })
      i = end + 1
      continue
    }

    if (ch === "[") {
      flush()
      var group = _parse(source, i + 1, depth + 1)
      nodes.push({ t: "g", alts: group.alts })
      i = group.i + 1
      continue
    }

    if (ch === "]" && depth > 0) break

    if (ch === "|" && depth > 0) {
      flush()
      alts.push(nodes)
      nodes = []
      i += 1
      continue
    }

    literal += ch
    i += 1
  }

  flush()
  alts.push(nodes)
  return { alts: alts, i: i }
}

function _value(name, values) {
  var v = values ? values[name] : undefined
  return v === undefined || v === null ? "" : String(v)
}

// resolved is false as soon as one tag came back empty, which is what decides
// whether an enclosing group survives. A nested group never invalidates its
// parent: dropping the inner half of "[%album% [%date%]]" should not take the
// album with it.
function _evalNodes(nodes, values) {
  var text = ""
  var resolved = true
  for (var i = 0; i < nodes.length; i++) {
    var node = nodes[i]
    if (node.t === "l") {
      text += node.v
    } else if (node.t === "t") {
      var value = _value(node.v, values)
      if (value === "") resolved = false
      else text += value
    } else {
      text += _evalAlts(node.alts, values).text
    }
  }
  return { text: text, resolved: resolved }
}

function _evalAlts(alts, values) {
  for (var i = 0; i < alts.length; i++) {
    var result = _evalNodes(alts[i], values)
    if (result.resolved) return result
  }
  return { text: "", resolved: false }
}

// Top level is deliberately forgiving: a missing tag there leaves a hole
// rather than blanking the label, because only brackets ask for all-or-nothing.
// Trimmed at the ends only. Runs of spaces inside are left alone because
// separators like "  ·  " are deliberate, and a hole left by a missing
// top-level tag is the format's own business.
function render(format, values) {
  var alts = parse(format)
  return _evalNodes(alts[0], values).text.trim()
}

// Every tag the panel advertises, in the order the help text lists them.
function tagNames() {
  return [
    "artist", "albumartist", "title", "album", "track", "disc", "date",
    "genre", "composer", "performer", "comment", "name", "file", "filename",
    "folder", "state", "stateicon", "elapsed", "duration", "remaining",
    "time", "position", "length", "volume", "bitrate", "audio",
    "repeat", "random", "single", "consume"
  ]
}
