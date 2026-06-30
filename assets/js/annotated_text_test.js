import { parseMarkers, tokenize, wrapLines, escapeHtml, buildHtml } from "./annotated_text.js"
import assert from "node:assert/strict"
import { describe, it } from "node:test"

// ── parseMarkers ────────────────────────────────────────

describe("parseMarkers", () => {
  it("parses an inline correction with type + explanation", () => {
    const segs = parseMarkers("Ich [[habe||bin||verb||Perfekt mit sein]] hier")
    assert.equal(segs.length, 3)
    assert.deepEqual(segs[0], { type: "text", text: "Ich " })
    assert.deepEqual(segs[1], {
      type: "correction",
      index: 0,
      original: "habe",
      corrected: "bin",
      explanation: "Perfekt mit sein",
    })
    assert.deepEqual(segs[2], { type: "text", text: " hier" })
  })

  it("indexes corrections sequentially", () => {
    const segs = parseMarkers("[[a||b||spelling||x]] und [[c||d||case||y]]")
    const corrections = segs.filter(s => s.type === "correction")
    assert.equal(corrections.length, 2)
    assert.equal(corrections[0].index, 0)
    assert.equal(corrections[1].index, 1)
  })

  it("explanation may itself contain a single pipe (last field)", () => {
    const segs = parseMarkers("[[a||b||case||use «a | b»]]")
    assert.equal(segs[0].explanation, "use «a | b»")
  })

  it("handles empty original (insertion)", () => {
    const segs = parseMarkers("test [[||,||punctuation||Komma]] end")
    assert.equal(segs[1].original, "")
    assert.equal(segs[1].corrected, ",")
  })

  it("handles empty corrected (deletion)", () => {
    const segs = parseMarkers("test [[removed||||other||extra]] end")
    assert.equal(segs[1].original, "removed")
    assert.equal(segs[1].corrected, "")
  })

  it("drops no-op markers (before == after) to plain text", () => {
    const segs = parseMarkers("a [[same||same||x||y]] b")
    assert.ok(segs.every(s => s.type === "text"))
    assert.equal(segs.map(s => s.text).join(""), "a same b")
  })

  it("skips markers with both sides empty", () => {
    const segs = parseMarkers("test [[||||x||y]] end")
    assert.ok(segs.every(s => s.type === "text"))
  })

  it("treats a marker with no || as plain text", () => {
    const segs = parseMarkers("test [[no separator]] end")
    const texts = segs.filter(s => s.type === "text").map(s => s.text).join("")
    assert.ok(texts.includes("[[no separator]]"))
  })

  it("handles unclosed marker as plain text", () => {
    const segs = parseMarkers("test [[unclosed||oops more text")
    assert.equal(segs.length, 1)
    assert.equal(segs[0].type, "text")
  })

  it("returns plain text when no markers", () => {
    const segs = parseMarkers("just plain text")
    assert.deepEqual(segs, [{ type: "text", text: "just plain text" }])
  })

  it("handles empty input", () => {
    assert.deepEqual(parseMarkers(""), [])
  })

  // legacy [[N:before||after]] entries still render, explanation from annMap
  describe("legacy format", () => {
    it("parses [[N:orig||corr]] and looks explanation up by id", () => {
      const segs = parseMarkers("Ich [[1:habe||bin]] hier", { 1: "fix this" })
      assert.equal(segs[1].original, "habe")
      assert.equal(segs[1].corrected, "bin")
      assert.equal(segs[1].explanation, "fix this")
    })

    it("legacy insertion / deletion still parse", () => {
      assert.equal(parseMarkers("[[2:||x]]")[0].corrected, "x")
      assert.equal(parseMarkers("[[3:y||]]")[0].original, "y")
    })
  })
})

// ── tokenize ────────────────────────────────────────────

describe("tokenize", () => {
  it("splits text into words", () => {
    const tokens = tokenize([{ type: "text", text: "eins zwei drei" }])
    assert.equal(tokens.length, 3)
  })

  it("preserves corrections as atomic tokens", () => {
    const tokens = tokenize([
      { type: "text", text: "before " },
      { type: "correction", index: 0, original: "a", corrected: "b", explanation: "" },
      { type: "text", text: " after" },
    ])
    assert.equal(tokens[1].type, "correction")
    assert.equal(tokens[1].index, 0)
  })

  it("handles newlines", () => {
    const tokens = tokenize([{ type: "text", text: "line1\nline2" }])
    assert.equal(tokens.filter(t => t.type === "newline").length, 1)
  })
})

// ── wrapLines ───────────────────────────────────────────

describe("wrapLines", () => {
  it("wraps at maxChars", () => {
    const tokens = tokenize([{ type: "text", text: "aaaa bbbb cccc dddd" }])
    assert.equal(wrapLines(tokens, 10).length, 2)
  })

  it("respects newlines", () => {
    const tokens = tokenize([{ type: "text", text: "line1\nline2" }])
    assert.equal(wrapLines(tokens, 80).length, 2)
  })

  it("preserves blank lines between paragraphs", () => {
    const tokens = tokenize([{ type: "text", text: "para1\n\npara2" }])
    const lines = wrapLines(tokens, 80)
    assert.equal(lines.length, 3)
    assert.equal(lines[1].segments.length, 0) // the blank line survives
  })

  it("tracks correction indexes per line", () => {
    const tokens = [
      { type: "text", text: "hello " },
      { type: "correction", index: 0, original: "a", corrected: "b", explanation: "fix" },
    ]
    const lines = wrapLines(tokens, 80)
    assert.equal(lines[0].corrections[0].index, 0)
    assert.equal(lines[0].corrections[0].explanation, "fix")
  })
})

// ── escapeHtml ──────────────────────────────────────────

describe("escapeHtml", () => {
  it("escapes angle brackets, ampersands, quotes", () => {
    assert.equal(escapeHtml("<b>a & \"b\"</b>"), "&lt;b&gt;a &amp; &quot;b&quot;&lt;/b&gt;")
  })
})

// ── buildHtml ───────────────────────────────────────────

describe("buildHtml", () => {
  it("renders corrections with strikethrough and added spans, no visible number", () => {
    const lines = [
      {
        segments: [{ type: "correction", index: 0, original: "bad", corrected: "good" }],
        corrections: [{ index: 0, explanation: "fix it" }],
      },
    ]
    const html = buildHtml(lines)
    assert.ok(html.includes("correction-deleted"))
    assert.ok(html.includes("correction-added"))
    assert.ok(html.includes("good"))
    assert.ok(!html.includes("correction-id")) // no superscript number
  })

  it("pairs notes to corrections by index via data attributes", () => {
    const lines = [
      {
        segments: [{ type: "text", text: "test " }, { type: "correction", index: 0, original: "a", corrected: "b" }],
        corrections: [{ index: 0, explanation: "reason" }],
      },
    ]
    const html = buildHtml(lines)
    assert.ok(html.includes("reason"))
    assert.ok(html.includes('data-note-for="0"'))
    assert.ok(html.includes('data-correction-index="0"'))
  })

  it("renders a blank line for an empty-segment line", () => {
    const html = buildHtml([{ segments: [], corrections: [] }])
    assert.ok(html.includes("&nbsp;"))
  })
})
