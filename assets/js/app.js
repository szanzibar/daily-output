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

  // Daily-reminder controls: subscribe/unsubscribe to Web Push and detect timezone.
  // The element carries data-vapid-key and data-timezone.
  Reminders: {
    mounted() {
      // Auto-detect timezone on first visit if the server has none yet.
      const browserTz = Intl.DateTimeFormat().resolvedOptions().timeZone
      if (!this.el.dataset.timezone && browserTz) {
        this.pushEvent("detect_timezone", { timezone: browserTz })
      }

      this.el.querySelector("[data-action=enable]")?.addEventListener("click", () => this.enable())
      this.el.querySelector("[data-action=disable]")?.addEventListener("click", () => this.disable())
      this.el.querySelector("[data-action=test]")?.addEventListener("click", () => this.pushEvent("test_notification", {}))
      this.el.querySelector("[data-action=detect-tz]")?.addEventListener("click", () => {
        const tz = Intl.DateTimeFormat().resolvedOptions().timeZone
        const input = this.el.querySelector("input[name=timezone]")
        if (input) input.value = tz
        this.pushEvent("set_timezone", { timezone: tz })
      })
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

    error(message) {
      const el = this.el.querySelector("[data-role=error]")
      if (el) { el.textContent = message; el.classList.remove("hidden") }
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

topbar.config({barColors: {0: "#000"}, shadowColor: "rgba(0, 0, 0, .5)"})
window.addEventListener("phx:page-loading-start", _info => topbar.show(300))
window.addEventListener("phx:page-loading-stop", _info => topbar.hide())

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
