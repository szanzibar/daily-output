import "phoenix_html"
import {Socket} from "phoenix"
import {LiveSocket} from "phoenix_live_view"
import {hooks as colocatedHooks} from "phoenix-colocated/sprachjournal"
import topbar from "../vendor/topbar"
import {parseMarkers, tokenize, wrapLines, buildHtml} from "./annotated_text"

// Hooks for LiveView
const Hooks = {
  ...colocatedHooks,

  // Auto-save textarea content to LiveView on input
  AutoSave: {
    mounted() {
      this.el.addEventListener("input", () => {
        this.pushEvent("update_body", { body: this.el.value })
      })
    }
  },

  // Auto-expanding textarea for chat input, Enter to send
  AutoExpand: {
    mounted() {
      this.el.addEventListener("input", () => this.resize())
      this.el.addEventListener("keydown", (e) => {
        if (e.key === "Enter" && !e.shiftKey) {
          e.preventDefault()
          this.el.closest("form").requestSubmit()
        }
      })
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

      // Wrap and render (pure logic)
      const lines = wrapLines(tokens, maxChars)
      this.el.innerHTML = buildHtml(lines, charW, maxChars)
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

// Register service worker for PWA (production only)
if ("serviceWorker" in navigator && process.env.NODE_ENV !== "development") {
  navigator.serviceWorker.register("/sw.js").catch(() => {})
} else if ("serviceWorker" in navigator) {
  navigator.serviceWorker.getRegistrations().then((registrations) => {
    registrations.forEach((r) => r.unregister())
  })
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
