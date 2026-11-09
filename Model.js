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
    hatched: Array.isArray(raw.hatched) ? raw.hatched.map(String) : [],
    railWidth: isFinite(rail) && rail >= 4 && rail <= 48 ? Math.floor(rail) : 0,
    // -1 = automatic: the gap Hyprland leaves at the top and bottom.
    verticalGap: raw.verticalGap !== undefined && isFinite(Number(raw.verticalGap)) ? Math.max(0, Math.floor(Number(raw.verticalGap))) : -1
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

// Whether an event's calendar is in a list of labels, whatever the case.
function inCalendars(ev, labels) {
  var label = String(ev.label || "").toLowerCase()
  return (labels || []).some(function (c) { return c.toLowerCase() === label })
}

// The timed events of today, finished ones included, soonest first. With a
// list of calendars, only the events of those.
function eventsOfDay(events, nowMs, calendars) {
  var dayStart = midnight(nowMs)
  var dayEnd = hourOf(dayStart, 24)
  return (events || []).filter(function (ev) {
    if (!ev || ev.allDay || ev.end <= ev.start || ev.end <= dayStart || ev.start >= dayEnd) return false
    return !(calendars || []).length || inCalendars(ev, calendars)
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
// sooner an event starting to blink, starting, ending or giving up on being
// joined (lateMs after its start). In an event's last minute, every second.
function nextWake(nowMs, events, imminentMs, lateMs) {
  var next = Math.floor(nowMs / 60000) * 60000 + 60000
  for (var i = 0; i < (events || []).length; i++) {
    var start = events[i].start
    var marks = [start - imminentMs, start, events[i].end]
    if (lateMs) marks.push(start + lateMs)
    if (start > nowMs && start - nowMs <= 60000) marks.push(Math.floor(nowMs / 1000) * 1000 + 1000)
    for (var j = 0; j < marks.length; j++)
      if (marks[j] > nowMs && marks[j] < next) next = marks[j]
  }
  return Math.max(250, next - nowMs + 20)
}

function eventKey(ev) { return String(ev.title || "") + "|" + ev.start }

function hasCall(ev) { return /^https?:\/\//i.test(String(ev.meetUrl || "")) }

// The started events a call in progress counts as joining: a call opened
// long before an event belongs to the previous one. callSince is 0 out of a
// call.
function joinedEvents(events, nowMs, callSince, imminentMs) {
  if (!callSince) return []
  return (events || []).filter(function (ev) {
    return ev.start <= nowMs && callSince >= ev.start - imminentMs
  })
}

// What an event is warning about: "imminent" in the last minutes before it,
// "late" for a while after its start until it is joined, or "". Only an
// event with a call can be late. One that started during a sleep (o.sleep:
// {from, to}) stays late for lateMs after the wake.
// o: {imminentMs, lateMs, sleep, acked: {eventKey: true}}.
function alertOf(ev, nowMs, o) {
  if (ev.start > nowMs) return ev.start - nowMs <= o.imminentMs ? "imminent" : ""
  if (!hasCall(ev) || ev.end <= nowMs || (o.acked && o.acked[eventKey(ev)])) return ""
  var limit = ev.start + o.lateMs
  if (o.sleep && ev.start > o.sleep.from && ev.start <= o.sleep.to) limit = Math.max(limit, o.sleep.to + o.lateMs)
  return nowMs < limit ? "late" : ""
}

// alertOf for each block, in order.
function alertStates(blocks, nowMs, o) {
  return (blocks || []).map(function (b) { return alertOf(b.event, nowMs, o) })
}

function wordCount(text) { return (String(text || "").match(/\S+/g) || []).length }

// Where each text of the card starts in the run of typed words, and how many
// words there are in all.
function typingPlan(texts) {
  var items = [], total = 0
  ;(texts || []).forEach(function (text) {
    var count = wordCount(text)
    items.push({ start: total, count: count })
    total += count
  })
  return { items: items, total: total }
}

// The part of text out once `typed` words of the whole run are.
function typedWords(text, plan, index, typed) {
  var item = plan.items[index]
  if (!item) return ""
  var left = Math.floor(typed) - item.start
  var words = /\S+/g
  var end = 0
  while (left-- > 0 && words.exec(text)) end = words.lastIndex
  return text.slice(0, end)
}

// The text the cursor is on: the one being typed, or the last when done.
function cursorItem(plan, typed) {
  var last = -1
  for (var i = 0; i < plan.items.length; i++) {
    var item = plan.items[i]
    if (!item.count) continue
    last = i
    if (Math.floor(typed) < item.start + item.count) return i
  }
  return last
}

// The card's header for a block: its rank among the events not over yet.
function targetLabel(blocks, index, nowMs) {
  var block = (blocks || [])[index]
  if (!block || block.event.end <= nowMs) return "TGT --"
  var ahead = blocks.filter(function (b) { return b.event.end > nowMs })
  return "TGT " + pad(ahead.indexOf(block) + 1) + "/" + pad(ahead.length)
}

// The events that both started and ended during a sleep.
function missedAsleep(events, sleep, calendars) {
  return (events || []).filter(function (ev) {
    if (!ev || ev.allDay || ev.end <= ev.start) return false
    if (!(ev.start > sleep.from && ev.end <= sleep.to)) return false
    return !(calendars || []).length || inCalendars(ev, calendars)
  })
}

// What a warning tag reads: minutes, seconds in the last minute before the
// start, and minutes since the start once late.
function tagText(ev, alert, nowMs) {
  if (alert === "late") return "T+" + pad(Math.min(99, Math.max(1, Math.ceil((nowMs - ev.start) / 60000))))
  var left = Math.max(0, ev.start - nowMs)
  return left <= 60000 ? "T-" + pad(Math.ceil(left / 1000)) + "s" : "T-" + pad(Math.ceil(left / 60000))
}

// The part of the screen past the rail that takes the pointer during a
// warning: from the first alerting block to the last, in window coordinates.
function alertZone(blocks, alerts, fromX, toX) {
  var top = Infinity, bottom = -Infinity
  for (var i = 0; i < (blocks || []).length; i++) {
    if (!alerts[i]) continue
    top = Math.min(top, blocks[i].y)
    bottom = Math.max(bottom, blocks[i].y + blocks[i].height)
  }
  if (bottom < top) return { x: 0, y: 0, width: 0, height: 0 }
  return { x: fromX, y: Math.max(0, top - 4), width: toX - fromX, height: bottom - top + 8 }
}

// Whether the calendars have not been fetched for too long, or ever.
function isStale(lastUpdated, nowMs, refreshMinutes) {
  if (!lastUpdated) return true
  return nowMs - lastUpdated > Math.max(15, 3 * (refreshMinutes || 0)) * 60000
}

// Where each block's warning tag starts on its cosine sweep, by block index.
// Among the imminent blocks, the first starts at the top of its block, the
// second at the bottom, and the others evenly between the two.
function sweepPhases(alerts) {
  var phases = (alerts || []).map(function () { return 0 })
  var alerting = []
  phases.forEach(function (_, i) { if (alerts[i]) alerting.push(i) })
  alerting.forEach(function (index, k) {
    var height = k === 0 ? 0 : k === 1 ? 1 : (k - 1) / (alerting.length - 1)
    phases[index] = Math.acos(1 - 2 * height) / Math.PI
  })
  return phases
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

// Meeting secrets out of a text shown on screen.
function maskSecrets(text) {
  return String(text || "")
    .replace(/((?:code secret|code d['’]acc[eè]s|mot de passe|passcode|password)\s*:?\s*)\S+/gi, "$1••••••")
    .replace(/(\bpin\b\s*:?\s*)\d[\d ]*#?/gi, "$1••••••")
    .replace(/([?&](?:p|pwd|passcode|pin)=)[^\s&]+/gi, "$1••••••")
}

// A calendar description, for the card: words only (they often come as
// HTML), no separator lines, and no meeting secrets on screen.
function plainDescription(text) {
  var plain = decodeEntities(String(text || "")
    .replace(/<br\s*\/?>|<\/p>|<\/li>/gi, "\n")
    .replace(/<[^>]*>/g, ""))
  return maskSecrets(plain
    .split("\n")
    .map(function (line) { return line.trim() })
    .filter(function (line) { return !/^[-_=~*.─━—–\s]*$/.test(line) })
    .join("\n"))
}

if (typeof module !== "undefined") {
  module.exports = {
    normalizeConfig: normalizeConfig, midnight: midnight, eventsOfDay: eventsOfDay, span: span,
    hourCells: hourCells, place: place, clock: clock, duration: duration, countdown: countdown, nextWake: nextWake, sweepPhases: sweepPhases, plainDescription: plainDescription,
    hasCall: hasCall, joinedEvents: joinedEvents, targetLabel: targetLabel,
    typingPlan: typingPlan, typedWords: typedWords, cursorItem: cursorItem, maskSecrets: maskSecrets,
    inCalendars: inCalendars, eventKey: eventKey, alertOf: alertOf, alertStates: alertStates, missedAsleep: missedAsleep,
    tagText: tagText, alertZone: alertZone, isStale: isStale
  }
}
