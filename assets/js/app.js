import "phoenix_html"
import {Socket} from "phoenix"
import {LiveSocket} from "phoenix_live_view"
import {hooks as colocatedHooks} from "phoenix-colocated/daily_output"
import topbar from "../vendor/topbar"
import {parseMarkers, tokenize, wrapLines, buildHtml, positionNotes} from "./annotated_text"

// Persist a field's value across LiveView navigation via localStorage.
// Restores on mount, saves on input, clears once its form is submitted.
// Opt in with `data-persist-key` (stable across remounts); falls back to the id.
function persistField(el) {
  const key = `persist:${el.dataset.persistKey || el.id}`
  const saved = window.localStorage.getItem(key)
  if (saved !== null && el.value === "") {
    el.value = saved
    el.dispatchEvent(new Event("input", {bubbles: true}))
  }
  el.addEventListener("input", () => window.localStorage.setItem(key, el.value))
  const form = el.closest("form")
  if (form) form.addEventListener("submit", () => window.localStorage.removeItem(key))
}

// Decode a base64url VAPID key into the Uint8Array pushManager wants.
function urlBase64ToUint8Array(base64String) {
  const padding = "=".repeat((4 - (base64String.length % 4)) % 4)
  const base64 = (base64String + padding).replace(/-/g, "+").replace(/_/g, "/")
  const raw = window.atob(base64)
  return Uint8Array.from([...raw].map(c => c.charCodeAt(0)))
}

// Hooks for LiveView
const Hooks = {
  ...colocatedHooks,

  // Auto-dismiss flash toasts. The timer resets whenever the message updates, so the
  // latest action is always what's shown (and visible for its full duration).
  Flash: {
    mounted() { this.schedule() },
    updated() { this.schedule() },
    destroyed() { clearTimeout(this.timer) },
    schedule() {
      clearTimeout(this.timer)
      const after = parseInt(this.el.dataset.dismissAfter || "3000", 10)
      this.timer = setTimeout(() => {
        this.liveSocket.execJS(this.el, this.el.getAttribute("phx-click"))
      }, after)
    }
  },

  // Daily-reminder controls: subscribe/unsubscribe to Web Push per device and
  // detect timezone. The element carries data-vapid-key and data-timezone.
  // Reminder state is per device: this browser is "on" iff it has a push
  // subscription the server knows about, so we report our endpoint on mount and
  // the server tells us which buttons to show.
  Reminders: {
    mounted() {
      // Auto-detect timezone on first visit if the server has none yet.
      const browserTz = Intl.DateTimeFormat().resolvedOptions().timeZone
      if (!this.el.dataset.timezone && browserTz) {
        this.pushEvent("detect_timezone", { timezone: browserTz })
      }

      // Delegate clicks: the enable/disable/test buttons are rendered
      // conditionally on the server, so they may not exist yet at mount.
      this.el.addEventListener("click", (e) => {
        const action = e.target.closest("[data-action]")?.dataset.action
        if (action === "enable") this.enable()
        else if (action === "disable") this.disable()
        else if (action === "test") this.test()
        else if (action === "detect-tz") this.detectTz()
      })

      this.reportStatus()
    },

    // Tell the server whether this browser currently holds a push subscription.
    async reportStatus() {
      this.pushEvent("device_status", { endpoint: await this.currentEndpoint() })
    },

    async enable() {
      try {
        if (!("serviceWorker" in navigator) || !("PushManager" in window)) {
          return this.error("This browser doesn't support notifications.")
        }
        const key = this.el.dataset.vapidKey
        if (!key) return this.error("Push keys aren't configured on the server.")

        const permission = await Notification.requestPermission()
        if (permission !== "granted") return this.error("Notifications are blocked. Allow them in your browser settings.")

        const reg = await navigator.serviceWorker.ready

        // Always start from a clean subscription: a leftover one created with a
        // different VAPID key makes subscribe() throw InvalidStateError.
        const existing = await reg.pushManager.getSubscription()
        if (existing) await existing.unsubscribe()

        const sub = await reg.pushManager.subscribe({
          userVisibleOnly: true,
          applicationServerKey: urlBase64ToUint8Array(key)
        })

        this.error("")
        this.pushEvent("enable_reminders", { subscription: sub.toJSON() })
      } catch (e) {
        console.error("enable reminders failed:", e)
        this.error(`Could not enable reminders: ${e.message || e.name}`)
      }
    },

    async disable() {
      try {
        const reg = await navigator.serviceWorker.ready
        const sub = await reg.pushManager.getSubscription()
        const endpoint = sub?.endpoint
        if (sub) await sub.unsubscribe()
        this.pushEvent("disable_reminders", endpoint ? { endpoint } : {})
      } catch (e) {
        this.pushEvent("disable_reminders", {})
      }
    },

    // Send the test only to this device.
    async test() {
      const endpoint = await this.currentEndpoint()
      this.pushEvent("test_notification", endpoint ? { endpoint } : {})
    },

    detectTz() {
      const tz = Intl.DateTimeFormat().resolvedOptions().timeZone
      const input = this.el.querySelector("input[name=timezone]")
      if (input) input.value = tz
      this.pushEvent("set_timezone", { timezone: tz })
    },

    // This browser's current push endpoint, or null if it isn't subscribed.
    async currentEndpoint() {
      try {
        if (!("serviceWorker" in navigator)) return null
        const reg = await navigator.serviceWorker.ready
        const sub = await reg.pushManager.getSubscription()
        return sub?.endpoint || null
      } catch (e) {
        return null
      }
    },

    error(message) {
      const el = this.el.querySelector("[data-role=error]")
      if (!el) return
      el.textContent = message
      el.classList.toggle("hidden", !message)
    }
  },

  // Auto-save textarea content to LiveView on input
  AutoSave: {
    mounted() {
      this.el.addEventListener("input", () => {
        this.pushEvent("update_body", { body: this.el.value })
      })
    }
  },

  // Auto-expanding textarea. Grows to fit its content as you type.
  // Submits on Enter unless `data-no-enter-submit` is set (multi-line composers),
  // and persists across navigation when `data-persist-key` is present.
  AutoExpand: {
    mounted() {
      this.el.addEventListener("input", () => this.resize())
      if (this.el.dataset.noEnterSubmit === undefined) {
        this.el.addEventListener("keydown", (e) => {
          if (e.key === "Enter" && !e.shiftKey) {
            e.preventDefault()
            this.el.closest("form").requestSubmit()
          }
        })
      }
      if (this.el.dataset.persistKey) persistField(this.el)
      this.resize()
    },
    resize() {
      this.el.style.height = "auto"
      this.el.style.height = this.el.scrollHeight + "px"
    }
  },

  // Tracks active foreground time on a page and pushes it to the server in batches.
  // Counts a second only when the tab is visible AND the user has interacted (keystroke,
  // click, tap, or scroll) within the last `idleMs` — so a page left open while you walk
  // away stops counting after the idle window instead of banking wall-clock time.
  // Flushes periodically and on hide/unmount. Set `data-section` to
  // ("entry" | "conversation" | "flashcards").
  TimeTracker: {
    // How long after the last interaction we keep counting (covers reading/thinking
    // pauses between actions). Bump this if genuine think-time gets undercounted.
    idleMs: 60000,
    activityEvents: ["keydown", "mousedown", "touchstart", "scroll", "input"],
    mounted() {
      this.section = this.el.dataset.section
      this.accMs = 0
      this.last = Date.now()
      // Treat landing on the page as a fresh interaction (grace from mount).
      this.lastActivity = Date.now()

      // Seal the elapsed interval with the OLD lastActivity before advancing it, so an
      // idle gap that preceded this interaction is never retroactively counted active.
      this.onActivity = () => {
        this.accumulate()
        this.lastActivity = Date.now()
      }
      this.activityEvents.forEach((evt) => {
        document.addEventListener(evt, this.onActivity, {passive: true, capture: true})
      })

      this.onVisibility = () => {
        this.accumulate()
        // Returning to the tab is itself a sign of presence.
        if (document.visibilityState === "visible") this.lastActivity = Date.now()
      }
      this.onHide = () => {
        this.accumulate()
        this.flush()
      }
      document.addEventListener("visibilitychange", this.onVisibility)
      window.addEventListener("pagehide", this.onHide)
      this.interval = setInterval(() => {
        this.accumulate()
        this.flush()
      }, 20000)
    },
    accumulate() {
      const now = Date.now()
      // Of the interval [last, now], count only the part that was both visible and
      // within idleMs of the last interaction.
      if (document.visibilityState === "visible") {
        const activeEnd = Math.min(now, this.lastActivity + this.idleMs)
        if (activeEnd > this.last) this.accMs += activeEnd - this.last
      }
      this.last = now
    },
    flush() {
      const secs = Math.floor(this.accMs / 1000)
      if (secs > 0) {
        this.pushEvent("track_time", {section: this.section, seconds: secs})
        this.accMs -= secs * 1000
      }
    },
    destroyed() {
      this.accumulate()
      this.flush()
      clearInterval(this.interval)
      this.activityEvents.forEach((evt) => {
        document.removeEventListener(evt, this.onActivity, {capture: true})
      })
      document.removeEventListener("visibilitychange", this.onVisibility)
      window.removeEventListener("pagehide", this.onHide)
    }
  },

  // Renders annotated text — DOM measurement only, logic in annotated_text.js
  AnnotatedText: {
    mounted() { this.render() },
    updated() { this.render() },

    render() {
      const raw = this.el.dataset.annotatedText || ""
      const annotations = JSON.parse(this.el.dataset.annotations || "[]")
      if (!raw) return

      const annMap = {}
      annotations.forEach(a => { annMap[a.id] = a.explanation })

      // Parse and tokenize (pure logic)
      const segments = parseMarkers(raw, annMap)
      const tokens = tokenize(segments)

      // Measure (DOM-dependent)
      const probe = document.createElement("span")
      probe.style.cssText = "font-family:var(--font-mono);font-size:0.95rem;visibility:hidden;position:absolute;white-space:pre"
      probe.textContent = "M"
      this.el.appendChild(probe)
      const charW = probe.getBoundingClientRect().width
      probe.remove()

      const containerW = this.el.clientWidth - 32
      const maxChars = Math.max(30, Math.floor(containerW / charW))

      // Wrap, render, then measure actual DOM positions for annotation alignment
      const lines = wrapLines(tokens, maxChars)
      this.el.innerHTML = buildHtml(lines)
      positionNotes(this.el)
    }
  }
}

const csrfToken = document.querySelector("meta[name='csrf-token']").getAttribute("content")
const liveSocket = new LiveSocket("/live", Socket, {
  longPollFallbackMs: 2500,
  params: {_csrf_token: csrfToken},
  hooks: Hooks,
})

// Client-rendered toasts. Driven by server `push_event(socket, "toast", %{message, kind})`,
// which fires on every event — so two changes in a row visibly dismiss the old toast and
// slide in a new one (Phoenix flash can't, since identical messages don't re-render).
function showToast(message, kind = "info") {
  const tray = document.getElementById("toast-tray")
  if (!tray || !message) return
  tray.querySelectorAll(".app-toast").forEach(dismissToast)

  const el = document.createElement("div")
  el.className =
    "app-toast border-4 border-ink px-4 py-3 font-black uppercase text-sm tracking-wide " +
    (kind === "error" ? "block-red" : "block-green")
  el.textContent = message
  el.addEventListener("click", () => dismissToast(el))
  tray.appendChild(el)

  requestAnimationFrame(() => el.classList.add("toast-in"))
  el._timer = setTimeout(() => dismissToast(el), kind === "error" ? 6000 : 2500)
}

function dismissToast(el) {
  if (el._dismissed) return
  el._dismissed = true
  clearTimeout(el._timer)
  el.classList.remove("toast-in")
  el.classList.add("toast-out")
  setTimeout(() => el.remove(), 220)
}

window.addEventListener("phx:toast", e => showToast(e.detail.message, e.detail.kind))

// Brutalist celebration: falling color blocks + a stamped headline. Fired by the
// server via `push_event(socket, "celebrate", %{kind, message})` when a day is
// completed or a streak milestone is hit. Pure DOM + CSS keyframes (see app.css),
// reduced-motion aware, and self-removing.
const CELEBRATE_COLORS = ["block-red", "block-blue", "block-yellow", "block-green", "block-pink", "block-cyan"]

function celebrate(detail = {}) {
  if (document.querySelector(".celebrate-overlay")) return // never stack bursts

  const overlay = document.createElement("div")
  overlay.className = "celebrate-overlay"
  overlay.setAttribute("aria-hidden", "true")

  for (let i = 0; i < 36; i++) {
    const block = document.createElement("span")
    block.className = `celebrate-block ${CELEBRATE_COLORS[i % CELEBRATE_COLORS.length]}`
    block.style.left = `${Math.random() * 100}vw`
    block.style.animationDelay = `${Math.random() * 0.5}s`
    block.style.animationDuration = `${1.8 + Math.random() * 1.2}s`
    block.style.setProperty("--spin", `${(Math.random() < 0.5 ? -1 : 1) * (360 + Math.random() * 540)}deg`)
    overlay.appendChild(block)
  }

  if (detail.message) {
    const msg = document.createElement("div")
    msg.className = "celebrate-message border-4 border-ink block-yellow"
    msg.textContent = detail.message
    overlay.appendChild(msg)
  }

  document.body.appendChild(overlay)
  setTimeout(() => overlay.remove(), 2800)
}

window.addEventListener("phx:celebrate", e => celebrate(e.detail))

// A quick, lightweight confetti pop for small wins (a correct flashcard). Fewer blocks,
// short and snappy, no headline, and self-removing so consecutive answers each get one.
function confettiBurst() {
  const overlay = document.createElement("div")
  overlay.className = "celebrate-overlay"
  overlay.setAttribute("aria-hidden", "true")

  for (let i = 0; i < 16; i++) {
    const block = document.createElement("span")
    block.className = `celebrate-block ${CELEBRATE_COLORS[i % CELEBRATE_COLORS.length]}`
    block.style.left = `${Math.random() * 100}vw`
    block.style.animationDelay = `${Math.random() * 0.15}s`
    block.style.animationDuration = `${0.9 + Math.random() * 0.5}s`
    block.style.setProperty("--spin", `${(Math.random() < 0.5 ? -1 : 1) * (360 + Math.random() * 360)}deg`)
    overlay.appendChild(block)
  }

  document.body.appendChild(overlay)
  setTimeout(() => overlay.remove(), 1500)
}

window.addEventListener("phx:confetti", () => confettiBurst())

topbar.config({barColors: {0: "#000"}, shadowColor: "rgba(0, 0, 0, .5)"})
window.addEventListener("phx:page-loading-start", _info => topbar.show(300))
window.addEventListener("phx:page-loading-stop", _info => {
  topbar.hide()
  // Close the mobile nav after navigating (the layout shell persists across nav).
  const navToggle = document.getElementById("nav-toggle")
  if (navToggle) navToggle.checked = false
})

liveSocket.connect()

window.liveSocket = liveSocket

// Register service worker for PWA + Web Push. Registered in all environments
// (localhost is a secure context) so push can be tested in dev. The SW is
// network-first, so it won't serve stale assets while developing.
if ("serviceWorker" in navigator) {
  navigator.serviceWorker.register("/sw.js").catch(() => {})
}

// Live reload dev features
if (process.env.NODE_ENV === "development") {
  window.addEventListener("phx:live_reload:attached", ({detail: reloader}) => {
    reloader.enableServerLogs()

    let keyDown
    window.addEventListener("keydown", e => keyDown = e.key)
    window.addEventListener("keyup", _e => keyDown = null)
    window.addEventListener("click", e => {
      if(keyDown === "c"){
        e.preventDefault()
        e.stopImmediatePropagation()
        reloader.openEditorAtCaller(e.target)
      } else if(keyDown === "d"){
        e.preventDefault()
        e.stopImmediatePropagation()
        reloader.openEditorAtDef(e.target)
      }
    }, true)

    window.liveReloader = reloader
  })
}
