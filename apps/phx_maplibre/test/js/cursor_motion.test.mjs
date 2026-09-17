import {test} from "node:test"
import assert from "node:assert/strict"
import {createCursorMotion} from "../../priv/js/editor/cursor_motion.mjs"

function fixture(options = {}) {
  let time = 0, nextId = 0
  const frames = new Map(), rendered = new Map()
  const motion = createCursorMotion({
    ...options, now: () => time,
    raf: fn => { frames.set(++nextId, fn); return nextId }, caf: id => frames.delete(id),
    render: (id, point) => rendered.set(id, [...point]),
  })
  const at = value => { time = value }
  function frame(value) {
    at(value)
    const callbacks = [...frames.values()]
    frames.clear()
    callbacks.forEach(fn => fn())
  }
  return {motion, rendered, frames, at, frame}
}

const close = (value, expected) => assert.ok(Math.abs(value - expected) < 1e-12, `${value} != ${expected}`)

test("new cursors snap, then tween linearly at the measured cadence and idle", () => {
  const {motion, rendered, frames, at, frame} = fixture()
  motion.update("alice", [0.1, 0.5])
  assert.deepEqual(rendered.get("alice"), [0.1, 0.5])
  assert.equal(frames.size, 0)
  at(100); motion.update("alice", [0.2, 0.6])
  frame(150)
  close(rendered.get("alice")[0], 0.15)
  close(rendered.get("alice")[1], 0.55)
  frame(200)
  close(rendered.get("alice")[0], 0.2)
  assert.equal(frames.size, 0)
})

test("a mid-flight update starts from the current interpolation without rewinding", () => {
  const {motion, rendered, at, frame} = fixture()
  motion.update("alice", [0.1, 0.5])
  at(100); motion.update("alice", [0.2, 0.5])
  frame(150)
  at(175); motion.update("alice", [0.3, 0.5])
  close(rendered.get("alice")[0], 0.175)
  frame(212.5)
  close(rendered.get("alice")[0], 0.2375)
  frame(250)
  close(rendered.get("alice")[0], 0.3)
})

test("other visitors' snapshots do not restart a cursor or alter its cadence", () => {
  const {motion, rendered, at, frame} = fixture()
  motion.update("alice", [0.1, 0.5])
  at(100); motion.update("alice", [0.2, 0.5])
  at(125); motion.update("alice", [0.2, 0.5]); motion.update("bob", [0.4, 0.5])
  frame(150)
  close(rendered.get("alice")[0], 0.15)
  frame(200)
  close(rendered.get("alice")[0], 0.2)
})

test("long pauses are capped at the default 500 ms interval and rapid bursts still get visible frames", () => {
  const {motion, rendered, at, frame} = fixture()
  motion.update("alice", [0.1, 0.5])
  at(5000); motion.update("alice", [0.2, 0.5])
  frame(5500)
  close(rendered.get("alice")[0], 0.2)
  at(5510); motion.update("bob", [0.2, 0.5])
  at(5515); motion.update("bob", [0.3, 0.5])
  frame(5532.5)
  close(rendered.get("bob")[0], 0.25)
  frame(5550)
  close(rendered.get("bob")[0], 0.3)
})

test("longitude crosses the antimeridian on the shortest path", () => {
  const {motion, rendered, at, frame} = fixture()
  motion.update("alice", [0.99, 0.5])
  at(100); motion.update("alice", [0.01, 0.5])
  frame(150)
  close(rendered.get("alice")[0], 1)
  frame(200)
  close(rendered.get("alice")[0], 1.01)
})

test("reduced motion snaps pending targets and suppresses subsequent frames", () => {
  const {motion, rendered, frames, at} = fixture()
  motion.update("alice", [0.1, 0.5])
  at(100); motion.update("alice", [0.2, 0.5])
  motion.setReducedMotion(true)
  close(rendered.get("alice")[0], 0.2)
  assert.equal(frames.size, 0)
  at(200); motion.update("alice", [0.3, 0.5])
  close(rendered.get("alice")[0], 0.3)
  assert.equal(frames.size, 0)
  motion.setReducedMotion(false)
  at(300); motion.update("alice", [0.4, 0.5])
  assert.equal(frames.size, 1)
})

test("removal, disconnect clearing, and destruction cancel animation frames", () => {
  const {motion, frames, rendered, at} = fixture()
  motion.update("alice", [0.1, 0.5])
  at(100); motion.update("alice", [0.2, 0.5])
  motion.remove("alice")
  assert.equal(frames.size, 0)
  motion.update("bob", [0.3, 0.5])
  at(200); motion.update("bob", [0.4, 0.5])
  motion.clear()
  assert.equal(frames.size, 0)
  motion.update("bob", [0.6, 0.5])
  assert.equal(frames.size, 0)
  close(rendered.get("bob")[0], 0.6)
  motion.destroy()
  motion.update("charlie", [0.7, 0.5])
  assert.equal(rendered.has("charlie"), false)
})

test("local interpolation toggle snaps active motion and resumes only on new updates", () => {
  const {motion, rendered, frames, at} = fixture()
  motion.update("alice", [0.1,0.5])
  at(100); motion.update("alice", [0.2,0.5])
  motion.setInterpolationEnabled(false)
  close(rendered.get("alice")[0], 0.2)
  assert.equal(frames.size, 0)
  at(200); motion.update("alice", [0.3,0.5])
  close(rendered.get("alice")[0], 0.3)
  assert.equal(frames.size, 0)
  motion.setInterpolationEnabled(true)
  assert.equal(frames.size, 0)
  at(300); motion.update("alice", [0.4,0.5])
  assert.equal(frames.size, 1)
})

test("shared intervals support long motion and shorten active motion without jumping", () => {
  const {motion, rendered, at, frame} = fixture()
  motion.setIntervalMs(2000)
  motion.update("alice", [0.1,0.5])
  at(2000); motion.update("alice", [0.2,0.5])
  frame(3000)
  close(rendered.get("alice")[0], 0.15)
  motion.setIntervalMs(25)
  close(rendered.get("alice")[0], 0.15)
  frame(3012.5)
  close(rendered.get("alice")[0], 0.175)
  frame(3025)
  close(rendered.get("alice")[0], 0.2)
})
