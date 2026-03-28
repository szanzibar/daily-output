/**
 * Pure business logic for parsing and laying out annotated text.
 * No DOM dependencies — all functions take data in, return data out.
 */

/**
 * Parse [[id:orig||corrected]] markers from raw annotated text.
 * Returns an array of {type: "text", text} and {type: "correction", id, original, corrected, explanation}.
 */
export function parseMarkers(raw, annMap = {}) {
  const segments = []
  const regex = /\[\[(\d+):([\s\S]*?)\]\]/g
  let lastIdx = 0
  let match

  while ((match = regex.exec(raw)) !== null) {
    if (match.index > lastIdx) {
      segments.push({ type: "text", text: raw.slice(lastIdx, match.index) })
    }

    const id = parseInt(match[1], 10)
    const inner = match[2]
    const sepIdx = inner.indexOf("||")

    if (sepIdx === -1) {
      // Malformed — no || delimiter, show as plain text
      segments.push({ type: "text", text: match[0] })
      lastIdx = regex.lastIndex
      continue
    }

    const orig = inner.slice(0, sepIdx)
    const corr = inner.slice(sepIdx + 2)

    if (!orig && !corr) {
      lastIdx = regex.lastIndex
      continue
    }

    segments.push({
      type: "correction",
      id,
      original: orig,
      corrected: corr,
      explanation: annMap[id] || ""
    })
    lastIdx = regex.lastIndex
  }

  if (lastIdx < raw.length) {
    segments.push({ type: "text", text: raw.slice(lastIdx) })
  }

  return segments
}

/**
 * Split segments into word-level tokens for line wrapping.
 * Corrections are kept as atomic (unsplittable) tokens.
 */
export function tokenize(segments) {
  const tokens = []

  for (const seg of segments) {
    if (seg.type === "correction") {
      tokens.push(seg)
    } else {
      for (const part of seg.text.split(/(\n)/)) {
        if (part === "\n") {
          tokens.push({ type: "newline" })
        } else {
          for (const word of part.split(/(?<=\s)/)) {
            if (word) tokens.push({ type: "text", text: word })
          }
        }
      }
    }
  }

  return tokens
}

/**
 * Character width of a token as rendered.
 */
export function tokenCharWidth(tok) {
  if (tok.type === "newline") return 0
  if (tok.type === "correction") return tok.original.length + tok.corrected.length + 2
  return tok.text.length
}

/**
 * Word-wrap tokens into lines of at most maxChars characters.
 * Each line has: segments[], corrections[] (with charOffset/charWidth), charPos.
 */
export function wrapLines(tokens, maxChars) {
  const lines = []
  let curLine = { segments: [], corrections: [], charPos: 0 }

  const pushLine = () => {
    if (curLine.segments.length > 0) lines.push(curLine)
    curLine = { segments: [], corrections: [], charPos: 0 }
  }

  for (const tok of tokens) {
    if (tok.type === "newline") {
      pushLine()
      continue
    }

    const tokLen = tokenCharWidth(tok)

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
    }

    curLine.segments.push(tok)
    curLine.charPos += tokLen
  }

  pushLine()
  return lines
}

/**
 * Escape HTML special characters.
 */
export function escapeHtml(str) {
  return str
    .replace(/&/g, "&amp;")
    .replace(/</g, "&lt;")
    .replace(/>/g, "&gt;")
    .replace(/"/g, "&quot;")
}

/**
 * Build the full HTML for annotated text lines.
 * charW = pixel width of one monospace character, maxChars = chars per line.
 */
export function buildHtml(lines, charW, maxChars) {
  let html = ""

  for (const line of lines) {
    html += `<div class="ann-line">`
    html += `<div class="ann-text-line">`

    for (const seg of line.segments) {
      if (seg.type === "text") {
        html += escapeHtml(seg.text)
      } else {
        html += `<span class="correction-inline">`
        if (seg.original) {
          html += `<span class="correction-deleted">${escapeHtml(seg.original)}</span>`
        }
        if (seg.corrected) {
          html += `<span class="correction-added">${escapeHtml(seg.corrected)}</span>`
        }
        html += `<sup class="correction-id">${seg.id}</sup>`
        html += `</span>`
      }
    }

    html += `</div>`

    for (const c of line.corrections) {
      const startCh = c.charOffset
      const containerPx = maxChars * charW
      const marginPx = Math.round(Math.min(startCh, maxChars * 0.5) * charW)
      const maxWidthPx = Math.round(containerPx - marginPx)
      html += `<div class="ann-note" style="margin-left:${marginPx}px;max-width:${maxWidthPx}px">`
      html += `<span class="ann-note-id">${c.id}</span> `
      html += `${escapeHtml(c.explanation)}`
      html += `</div>`
    }

    html += `</div>`
  }

  return html
}
