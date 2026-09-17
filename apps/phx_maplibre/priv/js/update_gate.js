/**
 * Browser-side send scheduling, independent of payloads and transport.
 * Samples use CSS pixels, velocities px/ms, and acceleration px/ms².
 * Keep queued operations/latest position in the caller; this gate stores neither.
 */
export function createUpdateGate({
  send,
  heartbeatMs = 500,
  minIntervalMs = 35,
  accelerationThreshold = 0.004,
  speedChangeThreshold = 0.12,
  minDistance = 2,
  smoothingMs = 40,
  now = () => performance.now(),
  setTimeout: setTimer = (callback, delay) => setTimeout(callback, delay),
  clearTimeout: clearTimer = timer => clearTimeout(timer),
}) {
  if (typeof send !== "function") throw new TypeError("An update gate needs a send callback")
  if (!([heartbeatMs, minIntervalMs, smoothingMs, accelerationThreshold, speedChangeThreshold, minDistance].every(Number.isFinite) &&
      heartbeatMs > 0 && minIntervalMs >= 0 && smoothingMs > 0 &&
      accelerationThreshold >= 0 && speedChangeThreshold >= 0 && minDistance >= 0)) {
    throw new RangeError("Invalid update gate thresholds")
  }
  let timer = null, deadline = Infinity, scheduledReason = null, pending = false, disposed = false
  let lastSent = now(), previous = null, velocity = null, sentVelocity = [0, 0], sentPoint = null
  const distance = (a, b) => Math.hypot(a[0] - b[0], a[1] - b[1])

  function cancelTimer() {
    if (timer !== null) clearTimer(timer)
    timer = null
    deadline = Infinity
    scheduledReason = null
  }

  function emit(reason) {
    if (disposed || !pending) return
    cancelTimer()
    pending = false
    lastSent = now()
    sentVelocity = velocity ? [...velocity] : [0, 0]
    sentPoint = previous ? [...previous.point] : null
    send(reason)
  }

  function schedule(at, reason) {
    if (timer !== null && deadline <= at) return
    cancelTimer()
    deadline = at
    scheduledReason = reason
    timer = setTimer(() => emit(reason), Math.max(0, at - now()))
  }

  function request({immediate = false} = {}) {
    if (disposed) return
    pending = true
    if (immediate) emit("interaction")
    else schedule(lastSent + heartbeatMs, "heartbeat")
  }

  function sample(point) {
    if (disposed) return
    if (!Array.isArray(point) || point.length !== 2 || !point.every(Number.isFinite)) {
      throw new TypeError("Expected a finite screen-space [x, y] position")
    }
    const time = now(), old = previous
    if (old && !distance(point, old.point)) return
    previous = {point: [...point], time}
    if (!old || time - old.time >= heartbeatMs) {
      velocity = null
      pending = true
      emit("start")
      return
    }
    request()
    const dt = time - old.time
    if (dt <= 0) return
    const raw = point.map((value, i) => (value - old.point[i]) / dt)
    if (!velocity) { velocity = raw; return }
    const gain = 1 - Math.exp(-dt / smoothingMs)
    const smoothed = velocity.map((value, i) => value + gain * (raw[i] - value))
    const acceleration = distance(smoothed, velocity) / dt
    velocity = smoothed
    if (acceleration >= accelerationThreshold && distance(velocity, sentVelocity) >= speedChangeThreshold &&
        (!sentPoint || distance(point, sentPoint) >= minDistance)) {
      schedule(Math.min(lastSent + heartbeatMs, Math.max(time, lastSent + Math.min(minIntervalMs, heartbeatMs))), "acceleration")
    }
  }

  function setHeartbeatMs(value) {
    if (!Number.isFinite(value) || value <= 0) throw new RangeError("Expected a positive finite heartbeat interval")
    if (disposed || value === heartbeatMs) return
    heartbeatMs = value
    const reason = scheduledReason || "heartbeat"
    cancelTimer()
    if (pending) {
      const at = reason === "acceleration"
        ? Math.min(lastSent + heartbeatMs, Math.max(now(), lastSent + Math.min(minIntervalMs, heartbeatMs)))
        : lastSent + heartbeatMs
      schedule(at, reason)
    }
  }

  function reset() {
    cancelTimer()
    pending = false
    previous = null
    velocity = null
    sentVelocity = [0, 0]
    sentPoint = null
    lastSent = now()
  }

  return Object.freeze({sample, request, setHeartbeatMs, flush: () => emit("flush"), reset,
    destroy() { reset(); disposed = true },
  })
}
