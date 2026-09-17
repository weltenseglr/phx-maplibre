// One frame loop for remote cursors. Positions are normalized Mercator x/y;
// markers retain geographic anchors when the receiving visitor pans or zooms.
export function createCursorMotion({
  render,
  reducedMotion = false,
  interpolationEnabled = true,
  intervalMs = 500,
  now = () => performance.now(),
  raf = callback => requestAnimationFrame(callback),
  caf = frame => cancelAnimationFrame(frame),
}) {
  const entries = new Map()
  let frame = null, disposed = false
  const same = (a, b) => a[0] === b[0] && a[1] === b[1]

  function position(entry, time) {
    const progress = entry.duration ? Math.min(Math.max((time - entry.start) / entry.duration, 0), 1) : 1
    return entry.from.map((value, i) => value + progress * (entry.to[i] - value))
  }

  function stop() {
    if (frame !== null) caf(frame)
    frame = null
  }

  function tick() {
    frame = null
    if (disposed) return
    const time = now()
    let moving = false
    for (const [id, entry] of entries) {
      if (!entry.duration) continue
      render(id, position(entry, time))
      if (time < entry.start + entry.duration) moving = true
      else entry.duration = 0
    }
    if (moving) frame = raf(tick)
  }

  function update(id, target) {
    if (disposed) return
    const time = now(), old = entries.get(id)
    // Presence snapshots include every visitor. Unchanged targets must not
    // restart a tween or change this visitor's measured movement cadence.
    if (old && same(old.target, target)) return
    const from = old ? position(old, time) : [...target]
    const to = [...target]
    // Choose the shortest longitude path across the antimeridian.
    to[0] = from[0] + (((target[0] - from[0] + 0.5) % 1 + 1) % 1 - 0.5)
    const duration = old && !reducedMotion && interpolationEnabled
      ? Math.min(Math.max(time - old.updatedAt, Math.min(35, intervalMs)), intervalMs) : 0
    entries.set(id, {from, to, target: [...target], start: time, duration, updatedAt: time})
    render(id, duration ? from : to)
    if (duration && frame === null) frame = raf(tick)
  }

  function remove(id) {
    entries.delete(id)
    if (![...entries.values()].some(entry => entry.duration)) stop()
  }

  function clear() { stop(); entries.clear() }

  function snap() {
    stop()
    for (const [id, entry] of entries) {
      entry.duration = 0
      render(id, entry.to)
    }
  }

  function setReducedMotion(value) {
    reducedMotion = value
    if (value && !disposed) snap()
  }

  function setInterpolationEnabled(value) {
    interpolationEnabled = value
    if (!value && !disposed) snap()
  }

  function setIntervalMs(value) {
    if (!Number.isFinite(value) || value <= 0) throw new RangeError("Expected a positive finite cursor interval")
    if (disposed || value === intervalMs) return
    intervalMs = value
    const time = now()
    for (const [id, entry] of entries) {
      if (!entry.duration) continue
      entry.from = position(entry, time)
      entry.duration = Math.min(Math.max(entry.start + entry.duration - time, 0), intervalMs)
      entry.start = time
      render(id, entry.duration ? entry.from : entry.to)
    }
    if (![...entries.values()].some(entry => entry.duration)) stop()
  }

  return {update, remove, clear, setReducedMotion, setInterpolationEnabled, setIntervalMs, destroy() { clear(); disposed = true }}
}
