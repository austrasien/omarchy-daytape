// Checks for Model.js, the tape's pure helpers: node --test test/*.test.js
const test = require("node:test")
const assert = require("node:assert/strict")
const M = require("../Model.js")

const day = new Date(2026, 10, 9).getTime()
const at = (h) => day + h * 3600000
const ev = (start, end, extra = {}) => ({ start: at(start), end: at(end), title: "t", ...extra })

test("config: defaults, swapped hours, calendars and rail", () => {
  const cfg = M.normalizeConfig({})
  assert.deepEqual([cfg.dayStart, cfg.dayEnd, cfg.calendars.length, cfg.railWidth], [6, 24, 0, 0])
  assert.equal(M.normalizeConfig({ dayStart: 20, dayEnd: 8 }).dayStart, 6)
  assert.equal(M.normalizeConfig({ railWidth: 14 }).railWidth, 14)
  assert.equal(M.normalizeConfig({ railWidth: 999 }).railWidth, 0)
})

test("eventsOfDay: keeps finished events, drops other days and all-day, filters calendars", () => {
  const list = [ev(9, 10), ev(11, 12, { label: "Work" }), ev(26, 27), ev(-5, -1), ev(0, 24, { allDay: true }), ev(13, 14, { label: "Perso" })]
  assert.equal(M.eventsOfDay(list, at(10.5)).length, 3)
  assert.equal(M.eventsOfDay(list, at(10.5), ["work"]).length, 1)
})

test("span: widens to whole hours around events", () => {
  const cfg = M.normalizeConfig({})
  const range = M.span(day, cfg, [ev(4.5, 7), ev(21, 22.5)])
  assert.equal(range.first, at(4))
  assert.equal(range.last, at(24))
})

test("place: to scale, with lanes for overlaps and a minimum height", () => {
  const range = { first: at(8), last: at(20) }
  const p = M.place([ev(10, 11), ev(11, 11.5), ev(11.25, 12), ev(15, 15.05)], range, 1200, 8)
  assert.deepEqual([p[0].y, p[0].height, p[0].lanes], [200, 100, 1])
  assert.deepEqual([p[1].lane, p[2].lane, p[1].lanes, p[2].lanes], [0, 1, 2, 2])
  assert.deepEqual([p[3].height, p[3].lanes], [8, 1])
})

test("nextWake: the next minute, or sooner a blink, start or end", () => {
  const five = 5 * 60000
  const now = at(10) + 10000
  assert.equal(M.nextWake(now, [], five), 50020)
  assert.equal(M.nextWake(now, [{ start: now + 5000 + five, end: now + 3600000 }], five), 5020)
  assert.equal(M.nextWake(now, [{ start: now + 7000, end: now + 3600000 }], five), 1020)   // the last minute ticks every second
  assert.equal(M.nextWake(now, [{ start: now - 60000, end: now + 9000 }], five), 9020)
})

test("plainDescription: words only, no separators, no secrets", () => {
  assert.equal(M.plainDescription("a<br>b &amp; <b>c</b> &#39;d&#x27;"), "a\nb & c 'd'")
  assert.equal(M.plainDescription("_____\n\nJoin\n-----\n"), "Join")
  assert.equal(M.plainDescription("Code secret : na6Nw7E3"), "Code secret : ••••••")
  assert.equal(M.plainDescription("Passcode: abc123"), "Passcode: ••••••")
  assert.equal(M.plainDescription("https://t.co/meet/38?p=Vhc7n&x=1"), "https://t.co/meet/38?p=••••••&x=1")
  assert.equal(M.plainDescription("<img src='https://x/y'>ok &unknown;"), "ok &unknown;")
})

test("warning tags start spread over the height", () => {
  const height = (phase) => (1 - Math.cos(Math.PI * phase)) / 2
  const heights = (alerts) => M.sweepPhases(alerts).map(height)
  const near = (got, want) => got.forEach((h, i) => assert.ok(Math.abs(h - want[i]) < 1e-9, `${i}: ${h}`))

  near(heights(["imminent"]), [0])
  near(heights(["imminent", "late"]), [0, 1])
  near(heights(["imminent", "imminent", "imminent"]), [0, 1, 0.5])
  near(heights(["late", "late", "late", "late"]), [0, 1, 1 / 3, 2 / 3])
  // Only the alerting ones count; the others stay at the top.
  near(heights(["", "imminent", "", "late"]), [0, 0, 0, 1])
})

const MIN = 60000
const alertOpts = { imminentMs: 5 * MIN, lateMs: 10 * MIN }
const span = (start, end) => ({ title: "x", start: day + start * MIN, end: day + end * MIN })

test("alert: imminent, then late until ten minutes after the start", () => {
  const ev = span(60, 120)
  const state = (mins, o) => M.alertOf(ev, day + mins * MIN, Object.assign({}, alertOpts, o))
  assert.equal(state(54), "")
  assert.equal(state(55), "imminent")
  assert.equal(state(59.9), "imminent")
  assert.equal(state(60), "late")
  assert.equal(state(69.9), "late")
  assert.equal(state(70), "")
})

test("alert: joining ends the late warning, not the imminent one", () => {
  const ev = span(60, 120)
  const acked = { [M.eventKey(ev)]: true }
  const o = Object.assign({ acked }, alertOpts)
  assert.equal(M.alertOf(ev, day + 58 * MIN, o), "imminent")
  assert.equal(M.alertOf(ev, day + 62 * MIN, o), "")
})

test("alert: an event started during a sleep is late for ten minutes after the wake", () => {
  const ev = span(60, 120)
  const sleep = { from: day + 30 * MIN, to: day + 90 * MIN }
  const o = Object.assign({ sleep }, alertOpts)
  assert.equal(M.alertOf(ev, day + 90 * MIN, o), "late")
  assert.equal(M.alertOf(ev, day + 99.9 * MIN, o), "late")
  assert.equal(M.alertOf(ev, day + 100 * MIN, o), "")
  // Started before the sleep: the ordinary limit.
  const before = span(20, 120)
  assert.equal(M.alertOf(before, day + 90 * MIN, o), "")
  // Over: nothing to join.
  assert.equal(M.alertOf(span(40, 80), day + 90 * MIN, o), "")
})

test("missedAsleep: started and over during the sleep", () => {
  const sleep = { from: day + 30 * MIN, to: day + 90 * MIN }
  const work = Object.assign(span(40, 80), { label: "Work" })
  const perso = Object.assign(span(40, 80), { label: "Perso" })
  const ongoing = Object.assign(span(60, 120), { label: "Work" })
  const earlier = Object.assign(span(10, 80), { label: "Work" })
  assert.deepEqual(M.missedAsleep([work, ongoing, earlier], sleep, []), [work])
  assert.deepEqual(M.missedAsleep([work, perso], sleep, ["perso"]), [perso])
})

test("tag text: minutes, last-minute seconds, then time since the start", () => {
  const ev = span(60, 120)
  const text = (mins, alert) => M.tagText(ev, alert, day + mins * MIN)
  assert.equal(text(56, "imminent"), "T-04")
  assert.equal(text(58.5, "imminent"), "T-02")
  assert.equal(text(59, "imminent"), "T-60s")
  assert.equal(text(59.5, "imminent"), "T-30s")
  assert.equal(text(60.1, "late"), "T+01")
  assert.equal(text(70, "late"), "T+10")
  assert.equal(text(400, "late"), "T+99")
})

test("nextWake ticks every second in the last minute and marks the end of the late warning", () => {
  const now = day + 10000
  const soon = { start: now + 30500, end: now + 3600000 }
  assert.equal(M.nextWake(now, [soon], 5 * MIN, 10 * MIN), 1020)
  const late = { start: now - 10 * MIN + 4000, end: now + 3600000 }
  assert.equal(M.nextWake(now, [late], 5 * MIN, 10 * MIN), 4020)
})

test("alert zone spans the alerting blocks only, past the rail", () => {
  const blocks = [{ y: 10, height: 5 }, { y: 100, height: 40 }, { y: 200, height: 20 }]
  assert.deepEqual(M.alertZone(blocks, ["", "late", "imminent"], 12, 56), { x: 12, y: 96, width: 44, height: 128 })
  assert.deepEqual(M.alertZone(blocks, ["", "", ""], 12, 56), { x: 0, y: 0, width: 0, height: 0 })
})

test("stale when never fetched or fetched too long ago", () => {
  const now = day + 600 * MIN
  assert.equal(M.isStale(0, now, 5), true)
  assert.equal(M.isStale(undefined, now, 5), true)
  assert.equal(M.isStale(now - 14 * MIN, now, 5), false)
  assert.equal(M.isStale(now - 16 * MIN, now, 5), true)
  assert.equal(M.isStale(now - 50 * MIN, now, 20), false)
})

test("hatched calendars come from the settings", () => {
  assert.deepEqual(M.normalizeConfig({ hatched: ["Perso"] }).hatched, ["Perso"])
  assert.deepEqual(M.normalizeConfig({}).hatched, [])
  assert.equal(M.inCalendars({ label: "perso" }, ["Perso"]), true)
  assert.equal(M.inCalendars({ label: "Work" }, ["Perso"]), false)
})

test("formats", () => {
  assert.equal(M.duration(45 * 60000), "45 min")
  assert.equal(M.duration(90 * 60000), "1 h 30")
  assert.equal(M.countdown(90.5 * 60000), "01:31")
})
