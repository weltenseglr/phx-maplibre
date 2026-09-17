import {test} from "node:test"
import assert from "node:assert/strict"
import {createUpdateGate} from "../../priv/js/update_gate.js"

test("timing and movement thresholds must be finite numbers", () => {
  for (const option of ["heartbeatMs", "minIntervalMs", "smoothingMs", "accelerationThreshold", "speedChangeThreshold", "minDistance"]) {
    for (const value of [Infinity, NaN, "35"]) {
      assert.throws(() => createUpdateGate({send() {}, [option]: value}), RangeError)
    }
  }
})

function fixture(options = {}) {
  let time = 0, nextId = 0
  const timers = new Map(), sends = []
  const gate = createUpdateGate({
    ...options, now: () => time,
    setTimeout: (fn, delay) => { const id = ++nextId; timers.set(id, {fn, at: time + delay}); return id },
    clearTimeout: id => timers.delete(id),
    send: reason => { sends.push({at: time, reason}); options.onSend?.() },
  })
  function advance(target) {
    for (;;) {
      const due = [...timers].sort((a, b) => a[1].at - b[1].at).find(([, timer]) => timer.at <= target)
      if (!due) break
      time = due[1].at
      timers.delete(due[0])
      due[1].fn()
    }
    time = target
  }
  return {gate, sends, advance, timers}
}

test("steady motion sends at the default 500 ms interval, including the final position, then idles", () => {
  const {gate, sends, advance, timers} = fixture()
  gate.sample([0, 0])
  for (let t = 50; t <= 1300; t += 50) { advance(t); gate.sample([t, 0]) }
  advance(1500)
  assert.deepEqual(sends.map(s => s.at), [0, 500, 1000, 1500])
  assert.equal(timers.size, 0)
  advance(2000)
  assert.equal(sends.length, 4)
})

test("acceleration sends sooner, respecting the minimum interval", () => {
  const {gate, sends, advance} = fixture()
  gate.sample([0, 0])
  advance(10); gate.sample([10, 0])
  advance(20); gate.sample([40, 0])
  advance(34)
  assert.equal(sends.length, 1)
  advance(35)
  assert.deepEqual(sends.at(-1), {at: 35, reason: "acceleration"})
  advance(40); gate.sample([100, 0])
  advance(50); gate.sample([200, 0])
  advance(69)
  assert.equal(sends.length, 2)
  advance(70)
  assert.equal(sends.at(-1).at, 70)
})

test("a direction change at constant speed also triggers an early send", () => {
  const {gate, sends, advance} = fixture()
  gate.sample([0, 0])
  advance(20); gate.sample([20, 0])
  advance(40); gate.sample([20, 20])
  advance(40)
  assert.deepEqual(sends.at(-1), {at: 40, reason: "acceleration"})
})

test("small pointer jitter waits for the heartbeat", () => {
  const {gate, sends, advance} = fixture()
  gate.sample([0, 0])
  for (let t = 10; t <= 100; t += 10) { advance(t); gate.sample([t % 20 ? 0.2 : 0, 0]) }
  assert.equal(sends.length, 1)
  advance(500)
  assert.equal(sends.length, 2)
})

test("interaction events bypass the minimum interval and flush queued work", () => {
  const {gate, sends, advance, timers} = fixture()
  gate.sample([0, 0])
  advance(5); gate.request()
  advance(6); gate.request({immediate: true})
  advance(7); gate.request({immediate: true})
  assert.deepEqual(sends.map(s => s.at), [0, 6, 7])
  assert.equal(timers.size, 0)
  gate.flush()
  assert.equal(sends.length, 3)
  gate.request(); gate.flush()
  assert.equal(sends.at(-1).reason, "flush")
})

test("requests read the caller's latest data and repeated samples do not send idle traffic", () => {
  let value = 0
  const values = []
  const {gate, sends, advance} = fixture({onSend: () => values.push(value)})
  gate.sample([0, 0])
  for (let t = 10; t <= 500; t += 10) { advance(t); gate.sample([0, 0]) }
  assert.equal(sends.length, 1)
  value = 1; gate.request()
  value = 2; gate.request()
  advance(500)
  assert.equal(sends.length, 2)
  assert.deepEqual(values, [0, 2])
})

test("reset and destruction cancel pending work, without stale motion on restart", () => {
  const {gate, sends, advance, timers} = fixture()
  gate.request()
  gate.reset()
  advance(500)
  assert.equal(sends.length, 0)
  gate.sample([100, 100])
  assert.deepEqual(sends, [{at: 500, reason: "start"}])
  gate.request()
  gate.destroy()
  gate.request({immediate: true}); gate.sample([200, 200]); gate.flush()
  advance(500)
  assert.equal(sends.length, 1)
  assert.equal(timers.size, 0)
})

test("changing the heartbeat reschedules pending work without dropping it", () => {
  const {gate, sends, advance} = fixture()
  gate.request()
  advance(50); gate.setHeartbeatMs(2000)
  advance(500)
  assert.equal(sends.length, 0)
  advance(2000)
  assert.deepEqual(sends, [{at:2000, reason:"heartbeat"}])
  gate.request()
  advance(2100); gate.setHeartbeatMs(25)
  advance(2100)
  assert.deepEqual(sends.at(-1), {at:2100, reason:"heartbeat"})
})

test("25 ms heartbeats work below the default acceleration minimum", () => {
  const {gate, sends, advance} = fixture({heartbeatMs:25})
  gate.sample([0,0])
  advance(10); gate.sample([10,0])
  advance(20); gate.sample([40,0])
  advance(25)
  assert.equal(sends.at(-1).at, 25)
  assert.throws(()=>gate.setHeartbeatMs(0), RangeError)
  assert.throws(()=>gate.setHeartbeatMs(Infinity), RangeError)
})

test("lengthening the heartbeat preserves an earlier acceleration approval", () => {
  const {gate, sends, advance} = fixture()
  gate.sample([0,0])
  advance(10); gate.sample([10,0])
  advance(20); gate.sample([40,0])
  advance(21); gate.setHeartbeatMs(2000)
  advance(35)
  assert.deepEqual(sends.at(-1), {at:35, reason:"acceleration"})
})
