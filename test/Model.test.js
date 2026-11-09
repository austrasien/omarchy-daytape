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

test("comingToday: drops past, tomorrow and all-day, filters calendars", () => {
  const list = [ev(9, 10), ev(11, 12, { label: "Work" }), ev(26, 27), ev(0, 24, { allDay: true }), ev(13, 14, { label: "Perso" })]
  assert.equal(M.comingToday(list, at(10.5)).length, 2)
  assert.equal(M.comingToday(list, at(10.5), ["work"]).length, 1)
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
  assert.equal(M.nextWake(now, [{ start: now + 7000, end: now + 3600000 }], five), 7020)
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

test("formats", () => {
  assert.equal(M.duration(45 * 60000), "45 min")
  assert.equal(M.duration(90 * 60000), "1 h 30")
  assert.equal(M.countdown(90.5 * 60000), "01:31")
})
