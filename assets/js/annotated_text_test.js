import { parseMarkers, tokenize, wrapLines, escapeHtml, buildHtml } from "./annotated_text.js"
import assert from "node:assert/strict"
import { describe, it } from "node:test"

// ── parseMarkers ────────────────────────────────────────

describe("parseMarkers", () => {
  it("parses simple correction", () => {
    const segs = parseMarkers("Ich [[1:habe||bin]] hier")
    assert.equal(segs.length, 3)
    assert.deepEqual(segs[0], { type: "text", text: "Ich " })
    assert.deepEqual(segs[1], { type: "correction", id: 1, original: "habe", corrected: "bin", explanation: "" })
    assert.deepEqual(segs[2], { type: "text", text: " hier" })
  })

  it("uses annotation map for explanations", () => {
    const segs = parseMarkers("[[1:a||b]]", { 1: "fix this" })
    assert.equal(segs[0].explanation, "fix this")
  })

  it("handles multiple corrections", () => {
    const segs = parseMarkers("[[1:a||b]] und [[2:c||d]]")
    const corrections = segs.filter(s => s.type === "correction")
    assert.equal(corrections.length, 2)
    assert.equal(corrections[0].id, 1)
    assert.equal(corrections[1].id, 2)
  })

  it("handles empty original (insertion)", () => {
    const segs = parseMarkers("test [[1:||inserted]] end")
    assert.equal(segs[1].original, "")
    assert.equal(segs[1].corrected, "inserted")
  })

  it("handles empty corrected (deletion)", () => {
    const segs = parseMarkers("test [[1:removed||]] end")
    assert.equal(segs[1].original, "removed")
    assert.equal(segs[1].corrected, "")
  })

  it("skips markers with both empty", () => {
    const segs = parseMarkers("test [[1:||]] end")
    // Both empty skipped, so we get "test " and " end" as text
    assert.ok(segs.every(s => s.type === "text"))
  })

  it("treats malformed marker (no ||) as plain text", () => {
    const segs = parseMarkers("test [[1:no separator]] end")
    const texts = segs.filter(s => s.type === "text").map(s => s.text).join("")
    assert.ok(texts.includes("[[1:no separator]]"))
  })

  it("handles unclosed marker as plain text", () => {
    const segs = parseMarkers("test [[1:unclosed||oops more text")
    assert.equal(segs.length, 1)
    assert.equal(segs[0].type, "text")
    assert.ok(segs[0].text.includes("[[1:unclosed"))
  })

  it("handles special characters in corrections", () => {
    const segs = parseMarkers('test [[1:B?||B?!]] end')
    assert.equal(segs[1].original, "B?")
    assert.equal(segs[1].corrected, "B?!")
  })

  it("handles pipe characters in text (not in markers)", () => {
    const segs = parseMarkers("a | b [[1:x||y]] c")
    assert.equal(segs[0].text, "a | b ")
    assert.equal(segs[1].type, "correction")
  })

  it("returns plain text when no markers", () => {
    const segs = parseMarkers("just plain text")
    assert.equal(segs.length, 1)
    assert.deepEqual(segs[0], { type: "text", text: "just plain text" })
  })

  it("handles empty input", () => {
    assert.deepEqual(parseMarkers(""), [])
  })
})

// ── tokenize ────────────────────────────────────────────

describe("tokenize", () => {
  it("splits text into words", () => {
    const tokens = tokenize([{ type: "text", text: "eins zwei drei" }])
    assert.equal(tokens.length, 3)
    assert.equal(tokens[0].text, "eins ")
    assert.equal(tokens[1].text, "zwei ")
    assert.equal(tokens[2].text, "drei")
  })

  it("preserves corrections as atomic tokens", () => {
    const tokens = tokenize([
      { type: "text", text: "before " },
      { type: "correction", id: 1, original: "a", corrected: "b", explanation: "" },
      { type: "text", text: " after" }
    ])
    assert.equal(tokens[1].type, "correction")
    assert.equal(tokens[1].id, 1)
  })

  it("handles newlines", () => {
    const tokens = tokenize([{ type: "text", text: "line1\nline2" }])
    const newlines = tokens.filter(t => t.type === "newline")
    assert.equal(newlines.length, 1)
  })
})

// ── wrapLines ───────────────────────────────────────────

describe("wrapLines", () => {
  it("wraps at maxChars", () => {
    const tokens = tokenize([{ type: "text", text: "aaaa bbbb cccc dddd" }])
    const lines = wrapLines(tokens, 10)
    assert.equal(lines.length, 2)
  })

  it("respects newlines", () => {
    const tokens = tokenize([{ type: "text", text: "line1\nline2" }])
    const lines = wrapLines(tokens, 80)
    assert.equal(lines.length, 2)
  })

  it("keeps corrections atomic (no splitting)", () => {
    const tokens = [
      { type: "text", text: "aaa " },
      { type: "correction", id: 1, original: "longword", corrected: "anotherlongword", explanation: "x" }
    ]
    const lines = wrapLines(tokens, 10)
    // Correction is too wide for line with "aaa ", so it should be on its own line
    assert.equal(lines.length, 2)
    assert.equal(lines[1].corrections.length, 1)
  })

  it("tracks correction IDs per line", () => {
    const tokens = [
      { type: "text", text: "hello " },
      { type: "correction", id: 1, original: "a", corrected: "b", explanation: "fix" }
    ]
    const lines = wrapLines(tokens, 80)
    assert.equal(lines[0].corrections[0].id, 1)
    assert.equal(lines[0].corrections[0].explanation, "fix")
  })
})

// ── escapeHtml ──────────────────────────────────────────

describe("escapeHtml", () => {
  it("escapes angle brackets", () => {
    assert.equal(escapeHtml("<b>test</b>"), "&lt;b&gt;test&lt;/b&gt;")
  })

  it("escapes ampersands", () => {
    assert.equal(escapeHtml("a & b"), "a &amp; b")
  })

  it("escapes quotes", () => {
    assert.equal(escapeHtml('"hi"'), "&quot;hi&quot;")
  })
})

// ── buildHtml ───────────────────────────────────────────

describe("buildHtml", () => {
  it("renders plain text lines", () => {
    const lines = [{ segments: [{ type: "text", text: "hello" }], corrections: [] }]
    const html = buildHtml(lines)
    assert.ok(html.includes("hello"))
    assert.ok(html.includes("ann-text-line"))
  })

  it("renders corrections with strikethrough and added spans", () => {
    const lines = [{
      segments: [{ type: "correction", id: 1, original: "bad", corrected: "good" }],
      corrections: [{ id: 1, explanation: "fix it" }]
    }]
    const html = buildHtml(lines)
    assert.ok(html.includes("correction-deleted"))
    assert.ok(html.includes("correction-added"))
    assert.ok(html.includes("bad"))
    assert.ok(html.includes("good"))
  })

  it("renders annotation notes with data attributes for positioning", () => {
    const lines = [{
      segments: [{ type: "text", text: "test " }, { type: "correction", id: 1, original: "a", corrected: "b" }],
      corrections: [{ id: 1, explanation: "reason" }]
    }]
    const html = buildHtml(lines)
    assert.ok(html.includes("ann-note"))
    assert.ok(html.includes("reason"))
    assert.ok(html.includes('data-note-for="1"'))
    assert.ok(html.includes('data-correction-id="1"'))
  })

  it("handles empty original (insertion)", () => {
    const lines = [{
      segments: [{ type: "correction", id: 1, original: "", corrected: "new" }],
      corrections: [{ id: 1, explanation: "added" }]
    }]
    const html = buildHtml(lines)
    assert.ok(!html.includes("correction-deleted"))
    assert.ok(html.includes("correction-added"))
    assert.ok(html.includes("new"))
  })
})
