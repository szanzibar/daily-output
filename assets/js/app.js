// If you want to use Phoenix channels, run `mix help phx.gen.channel`
// to get started and then uncomment the line below.
// import "./user_socket.js"

// You can include dependencies in two ways.
//
// The simplest option is to put them in assets/vendor and
// import them using relative paths:
//
//     import "../vendor/some-package.js"
//
// Alternatively, you can `npm install some-package --prefix assets` and import
// them using a path starting with the package name:
//
//     import "some-package"
//
// If you have dependencies that try to import CSS, esbuild will generate a separate `app.css` file.
// To load it, simply add a second `<link>` to your `root.html.heex` file.

// Include phoenix_html to handle method=PUT/DELETE in forms and buttons.
import "phoenix_html"
// Establish Phoenix Socket and LiveView configuration.
import {Socket} from "phoenix"
import {LiveSocket} from "phoenix_live_view"
import {hooks as colocatedHooks} from "phoenix-colocated/sprachjournal"
import topbar from "../vendor/topbar"

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

  // Renders annotated text with corrections + annotations
  // Measures container width to word-wrap at the right character count
  AnnotatedText: {
    mounted() { this.render() },
    updated() { this.render() },

    render() {
      const raw = this.el.dataset.annotatedText || ""
      const annotations = JSON.parse(this.el.dataset.annotations || "[]")
      if (!raw) return

      const annMap = {}
      annotations.forEach(a => { annMap[a.id] = a.explanation })

      // Parse [[id:orig||corrected]] markers
      const segments = []
      const regex = /\[\[(\d+):(.+?)\|\|(.+?)\]\]/g
      let lastIdx = 0
      let match
      while ((match = regex.exec(raw)) !== null) {
        if (match.index > lastIdx) {
          segments.push({ type: "text", text: raw.slice(lastIdx, match.index) })
        }
        segments.push({
          type: "correction",
          id: parseInt(match[1]),
          original: match[2],
          corrected: match[3],
          explanation: annMap[parseInt(match[1])] || ""
        })
        lastIdx = regex.lastIndex
      }
      if (lastIdx < raw.length) {
        segments.push({ type: "text", text: raw.slice(lastIdx) })
      }

      // Measure how many monospace chars fit in the container
      const probe = document.createElement("span")
      probe.style.fontFamily = "var(--font-mono)"
      probe.style.fontSize = "0.95rem"
      probe.style.visibility = "hidden"
      probe.style.position = "absolute"
      probe.style.whiteSpace = "pre"
      probe.textContent = "M"
      this.el.appendChild(probe)
      const charW = probe.getBoundingClientRect().width
      probe.remove()

      const containerW = this.el.clientWidth - 32 // padding
      const maxChars = Math.max(30, Math.floor(containerW / charW))

      // Tokenize: split text segments into words, keep corrections atomic
      const tokens = []
      segments.forEach(seg => {
        if (seg.type === "correction") {
          tokens.push(seg)
        } else {
          // Split on newlines first, then words
          seg.text.split(/(\n)/).forEach(part => {
            if (part === "\n") {
              tokens.push({ type: "newline" })
            } else {
              // Split keeping trailing whitespace with each word
              part.split(/(?<=\s)/).forEach(word => {
                if (word) tokens.push({ type: "text", text: word })
              })
            }
          })
        }
      })

      // Word-wrap into lines
      const lines = []
      let curLine = { segments: [], corrections: [], charPos: 0 }

      const pushLine = () => {
        if (curLine.segments.length > 0) lines.push(curLine)
        curLine = { segments: [], corrections: [], charPos: 0 }
      }

      tokens.forEach(tok => {
        if (tok.type === "newline") {
          pushLine()
          return
        }

        const tokLen = tok.type === "correction"
          ? tok.original.length + tok.corrected.length + 2
          : tok.text.length

        if (curLine.charPos > 0 && curLine.charPos + tokLen > maxChars) {
          pushLine()
        }

        if (tok.type === "correction") {
          curLine.corrections.push({
            id: tok.id,
            explanation: tok.explanation,
            charOffset: curLine.charPos,
            charWidth: tokLen
          })
          curLine.segments.push(tok)
        } else {
          curLine.segments.push(tok)
        }
        curLine.charPos += tokLen
      })
      pushLine()

      // Render HTML
      let html = ""
      lines.forEach(line => {
        html += `<div class="ann-line">`

        // Text line
        html += `<div class="ann-text-line">`
        line.segments.forEach(seg => {
          if (seg.type === "text") {
            html += escapeHtml(seg.text)
          } else {
            html += `<span class="correction-inline">`
            html += `<span class="correction-deleted">${escapeHtml(seg.original)}</span>`
            html += `<span class="correction-added">${escapeHtml(seg.corrected)}</span>`
            html += `<sup class="correction-id">${seg.id}</sup>`
            html += `</span>`
          }
        })
        html += `</div>`

        // Annotations — each on its own line, indented to align near correction
        if (line.corrections.length > 0) {
          line.corrections.forEach(c => {
            // Calculate indent: center of correction, clamped to stay in bounds
            const centerCh = c.charOffset + Math.floor(c.charWidth / 2)
            // Clamp: don't start before 0 or too far right
            const indent = Math.max(0, Math.min(centerCh, maxChars - 15))
            html += `<div class="ann-note" style="padding-left:${indent}ch">`
            html += `<span class="ann-note-id">${c.id}</span> `
            html += `${escapeHtml(c.explanation)}`
            html += `</div>`
          })
        }

        html += `</div>`
      })

      this.el.innerHTML = html
    }
  }
}

function escapeHtml(str) {
  const div = document.createElement("div")
  div.textContent = str
  return div.innerHTML
}

const csrfToken = document.querySelector("meta[name='csrf-token']").getAttribute("content")
const liveSocket = new LiveSocket("/live", Socket, {
  longPollFallbackMs: 2500,
  params: {_csrf_token: csrfToken},
  hooks: Hooks,
})

// Show progress bar on live navigation and form submits
topbar.config({barColors: {0: "#000"}, shadowColor: "rgba(0, 0, 0, .5)"})
window.addEventListener("phx:page-loading-start", _info => topbar.show(300))
window.addEventListener("phx:page-loading-stop", _info => topbar.hide())

// connect if there are any LiveViews on the page
liveSocket.connect()

// expose liveSocket on window for web console debug logs and latency simulation:
// >> liveSocket.enableDebug()
// >> liveSocket.enableLatencySim(1000)  // enabled for duration of browser session
// >> liveSocket.disableLatencySim()
window.liveSocket = liveSocket

// Register service worker for PWA (production only — don't cache in dev)
if ("serviceWorker" in navigator && process.env.NODE_ENV !== "development") {
  navigator.serviceWorker.register("/sw.js").catch(() => {})
} else if ("serviceWorker" in navigator) {
  // Unregister any existing SW in dev to prevent stale caches
  navigator.serviceWorker.getRegistrations().then((registrations) => {
    registrations.forEach((r) => r.unregister())
  })
}

// The lines below enable quality of life phoenix_live_reload
// development features:
//
//     1. stream server logs to the browser console
//     2. click on elements to jump to their definitions in your code editor
//
if (process.env.NODE_ENV === "development") {
  window.addEventListener("phx:live_reload:attached", ({detail: reloader}) => {
    // Enable server log streaming to client.
    // Disable with reloader.disableServerLogs()
    reloader.enableServerLogs()

    // Open configured PLUG_EDITOR at file:line of the clicked element's HEEx component
    //
    //   * click with "c" key pressed to open at caller location
    //   * click with "d" key pressed to open at function component definition location
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

