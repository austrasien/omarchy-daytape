// Pure helpers for the day tape. No Qt imports, so node can load it.

var HOUR_MS = 3600000

function clampHour(value, fallback) {
  var n = Number(value)
  return isFinite(n) && n >= 0 && n <= 24 ? Math.floor(n) : fallback
}

function normalizeConfig(raw) {
  raw = raw || {}
  var start = clampHour(raw.dayStart, 6)
  var end = clampHour(raw.dayEnd, 24)
  if (end <= start) { start = 6; end = 24 }
  var calendars = Array.isArray(raw.calendars) ? raw.calendars.map(String) : []
  var rail = Number(raw.railWidth)
  return {
    dayStart: start, dayEnd: end, calendars: calendars, visible: raw.visible !== false,
    monitor: typeof raw.monitor === "string" ? raw.monitor : "",
    railWidth: isFinite(rail) && rail >= 4 && rail <= 48 ? Math.floor(rail) : 0
  }
}

function hourOf(dayMs, hour) {
  var d = new Date(dayMs)
  d.setHours(hour, 0, 0, 0)
  return d.getTime()
}

function midnight(ms) {
  var d = new Date(ms)
  d.setHours(0, 0, 0, 0)
  return d.getTime()
}

// The timed events of today not over yet, soonest first. With a list of
// calendars, only the events of those (by label, whatever the case).
function comingToday(events, nowMs, calendars) {
  var wanted = (calendars || []).map(function (c) { return c.toLowerCase() })
  var dayEnd = hourOf(midnight(nowMs), 24)
  return (events || []).filter(function (ev) {
    if (!ev || ev.allDay || ev.end <= ev.start || ev.end <= nowMs || ev.start >= dayEnd) return false
    return !wanted.length || wanted.indexOf(String(ev.label || "").toLowerCase()) !== -1
  }).sort(function (a, b) {
    return a.start - b.start || a.end - b.end
  })
}

// The hours the tape spans: the configured ones, widened to whole hours for
// any event falling outside them.
function span(dayMs, cfg, events) {
  var dayEnd = hourOf(dayMs, 24)
  var first = hourOf(dayMs, cfg.dayStart)
  var last = hourOf(dayMs, cfg.dayEnd)
  for (var i = 0; i < (events || []).length; i++) {
    var start = Math.max(events[i].start, dayMs)
    var end = Math.min(events[i].end, dayEnd)
    if (start < first) first = hourOf(dayMs, new Date(start).getHours())
    if (end > last) {
      var d = new Date(end)
      last = hourOf(dayMs, d.getHours() + (d.getMinutes() || d.getSeconds() ? 1 : 0))
    }
  }
  return { first: first, last: last }
}

// The hours of the span, one cell each, top to bottom.
function hourCells(range, height) {
  var cells = []
  var total = range.last - range.first
  if (total <= 0 || height <= 0) return cells
  for (var t = range.first; t < range.last; t += HOUR_MS) {
    var y = (t - range.first) / total * height
    cells.push({ y: y, height: HOUR_MS / total * height, hour: new Date(t).getHours() })
  }
  return cells
}

// Each event as a block to scale. Blocks that would touch share the width,
// one lane each; every block is at least minHeight tall to stay hoverable.
function place(events, range, height, minHeight) {
  var total = range.last - range.first
  if (total <= 0 || height <= 0) return []
  var blocks = []
  var cluster = []
  var clusterBottom = -1

  function closeCluster() {
    var lanes = 0
    for (var i = 0; i < cluster.length; i++) lanes = Math.max(lanes, cluster[i].lane + 1)
    for (var j = 0; j < cluster.length; j++) cluster[j].lanes = lanes
    cluster = []
  }

  var laneBottoms = []
  for (var i = 0; i < (events || []).length; i++) {
    var ev = events[i]
    var top = (Math.max(ev.start, range.first) - range.first) / total * height
    var bottom = (Math.min(ev.end, range.last) - range.first) / total * height
    var h = Math.max(minHeight, bottom - top)
    top = Math.min(top, height - h)

    if (cluster.length && top >= clusterBottom) {
      closeCluster()
      laneBottoms = []
      clusterBottom = -1
    }
    var lane = 0
    while (lane < laneBottoms.length && laneBottoms[lane] > top) lane++
    laneBottoms[lane] = top + h
    clusterBottom = Math.max(clusterBottom, top + h)

    var block = { event: ev, y: top, height: h, lane: lane, lanes: 1 }
    cluster.push(block)
    blocks.push(block)
  }
  closeCluster()
  return blocks
}

function pad(n) { return (n < 10 ? "0" : "") + n }

function clock(ms, use12Hour) {
  var d = new Date(ms)
  var h = d.getHours(), m = d.getMinutes()
  if (!use12Hour) return pad(h) + ":" + pad(m)
  return ((h + 11) % 12 + 1) + (m ? ":" + pad(m) : "") + (h < 12 ? " am" : " pm")
}

function duration(ms) {
  var mins = Math.round(ms / 60000)
  if (mins < 60) return mins + " min"
  var h = Math.floor(mins / 60), m = mins % 60
  return h + " h" + (m ? " " + pad(m) : "")
}

// Time left as HH:MM, rounded up to the minute.
function countdown(ms) {
  var mins = Math.max(0, Math.ceil(ms / 60000))
  return pad(Math.floor(mins / 60)) + ":" + pad(mins % 60)
}

// Milliseconds to the next moment the tape changes: the next minute, or
// sooner an event starting to blink, starting or ending.
function nextWake(nowMs, events, imminentMs) {
  var next = Math.floor(nowMs / 60000) * 60000 + 60000
  for (var i = 0; i < (events || []).length; i++) {
    var marks = [events[i].start - imminentMs, events[i].start, events[i].end]
    for (var j = 0; j < marks.length; j++)
      if (marks[j] > nowMs && marks[j] < next) next = marks[j]
  }
  return Math.max(250, next - nowMs + 20)
}

function decodeEntities(text) {
  var named = { amp: "&", lt: "<", gt: ">", quot: '"', apos: "'", nbsp: " " }
  return text.replace(/&(#x[0-9a-f]+|#\d+|[a-z]+);/gi, function (whole, code) {
    if (code.charAt(0) !== "#") {
      var key = code.toLowerCase()
      return Object.prototype.hasOwnProperty.call(named, key) ? named[key] : whole
    }
    var n = /^#x/i.test(code) ? parseInt(code.slice(2), 16) : parseInt(code.slice(1), 10)
    return n > 0 && n <= 0x10ffff ? String.fromCodePoint(n) : whole
  })
}

// A calendar description, for the card: words only (they often come as
// HTML), no separator lines, and no meeting secrets on screen.
function plainDescription(text) {
  var plain = decodeEntities(String(text || "")
    .replace(/<br\s*\/?>|<\/p>|<\/li>/gi, "\n")
    .replace(/<[^>]*>/g, ""))
  return plain
    .split("\n")
    .map(function (line) { return line.trim() })
    .filter(function (line) { return !/^[-_=~*.─━—–\s]*$/.test(line) })
    .join("\n")
    .replace(/((?:code secret|code d['’]acc[eè]s|mot de passe|passcode|password)\s*:?\s*)\S+/gi, "$1••••••")
    .replace(/([?&](?:p|pwd|passcode)=)[^\s&]+/gi, "$1••••••")
}

if (typeof module !== "undefined") {
  module.exports = {
    normalizeConfig: normalizeConfig, midnight: midnight, comingToday: comingToday, span: span,
    hourCells: hourCells, place: place, clock: clock, duration: duration, countdown: countdown, nextWake: nextWake, plainDescription: plainDescription
  }
}
