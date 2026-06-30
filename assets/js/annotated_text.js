/**
 * Pure business logic for parsing and laying out annotated text.
 * No DOM dependencies — all functions take data in, return data out.
 */

/**
 * Parse correction markers from raw annotated text.
 *
 * Current format is [[before||after||type||explanation]] — each marker carries its own
 * explanation inline, so corrections need no id. Legacy entries use [[N:before||after]] with a
 * numeric id and look the explanation up in annMap. Corrections get a sequential `index` so the
 * renderer can pair each note with its correction by order.
 *
 * Returns an array of {type:"text", text} and {type:"correction", index, original, corrected, explanation}.
 */
export function parseMarkers(raw, annMap = {}) {
  const segments = [];
  const regex = /\[\[([\s\S]*?)\]\]/g;
  let lastIdx = 0;
  let match;
  let index = 0;

  while ((match = regex.exec(raw)) !== null) {
    if (match.index > lastIdx) {
      segments.push({ type: 'text', text: raw.slice(lastIdx, match.index) });
    }

    let inner = match[1];

    // Legacy markers carry a numeric "N:" id prefix; the explanation lives in annMap.
    const legacy = inner.match(/^(\d+):/);
    const legacyId = legacy ? parseInt(legacy[1], 10) : null;
    if (legacy) inner = inner.slice(legacy[0].length);

    const parts = inner.split('||');

    if (parts.length < 2) {
      // No || delimiter — malformed, show as plain text
      segments.push({ type: 'text', text: match[0] });
      lastIdx = regex.lastIndex;
      continue;
    }

    const original = parts[0];
    const corrected = parts[1];

    if ((!original && !corrected) || original === corrected) {
      // both-empty or no-op (flagged then kept) — drop to plain text
      if (original) segments.push({ type: 'text', text: original });
      lastIdx = regex.lastIndex;
      continue;
    }

    // New format carries the explanation as the last field; legacy looks it up by id.
    const explanation =
      parts.length >= 4 ? parts.slice(3).join('||') : legacyId !== null ? annMap[legacyId] || '' : '';

    segments.push({ type: 'correction', index, original, corrected, explanation });
    index++;
    lastIdx = regex.lastIndex;
  }

  if (lastIdx < raw.length) {
    segments.push({ type: 'text', text: raw.slice(lastIdx) });
  }

  return segments;
}

/**
 * Split segments into word-level tokens for line wrapping.
 * Corrections are kept as atomic (unsplittable) tokens.
 */
export function tokenize(segments) {
  const tokens = [];

  for (const seg of segments) {
    if (seg.type === 'correction') {
      tokens.push(seg);
    } else {
      for (const part of seg.text.split(/(\n)/)) {
        if (part === '\n') {
          tokens.push({ type: 'newline' });
        } else {
          for (const word of part.split(/(?<=\s)/)) {
            if (word) tokens.push({ type: 'text', text: word });
          }
        }
      }
    }
  }

  return tokens;
}

/**
 * Character width of a token for line-wrap decisions.
 */
function tokenCharWidth(tok) {
  if (tok.type === 'newline') return 0;
  if (tok.type === 'correction') return tok.original.length + tok.corrected.length + 2;
  return tok.text.length;
}

/**
 * Word-wrap tokens into lines of at most maxChars characters.
 * Each line has: segments[] and corrections[] (indexes only — positioning is done via DOM measurement).
 * A newline always ends the current line, so consecutive newlines preserve blank lines between paragraphs.
 */
export function wrapLines(tokens, maxChars) {
  const lines = [];
  let curLine = { segments: [], corrections: [], charPos: 0 };
  const newLine = () => {
    curLine = { segments: [], corrections: [], charPos: 0 };
  };

  for (const tok of tokens) {
    if (tok.type === 'newline') {
      lines.push(curLine); // push even if empty → blank lines survive
      newLine();
      continue;
    }

    const tokLen = tokenCharWidth(tok);

    if (curLine.charPos > 0 && curLine.charPos + tokLen > maxChars) {
      lines.push(curLine);
      newLine();
    }

    if (tok.type === 'correction') {
      curLine.corrections.push({ index: tok.index, explanation: tok.explanation });
    }

    curLine.segments.push(tok);
    curLine.charPos += tokLen;
  }

  if (curLine.segments.length > 0) lines.push(curLine);
  return lines;
}

/**
 * Escape HTML special characters.
 */
export function escapeHtml(str) {
  return str.replace(/&/g, '&amp;').replace(/</g, '&lt;').replace(/>/g, '&gt;').replace(/"/g, '&quot;');
}

/**
 * Build the full HTML for annotated text lines.
 * charW = pixel width of one monospace character, maxChars = chars per line.
 */
export function buildHtml(lines) {
  let html = '';

  for (const line of lines) {
    html += `<div class="ann-line">`;
    html += `<div class="ann-text-line">`;

    if (line.segments.length === 0) {
      // blank paragraph line — keep it visible
      html += '&nbsp;';
    }

    for (const seg of line.segments) {
      if (seg.type === 'text') {
        html += escapeHtml(seg.text);
      } else {
        html += `<span class="correction-inline" data-correction-index="${seg.index}">`;
        if (seg.original) {
          html += `<span class="correction-deleted">${escapeHtml(seg.original)}</span>`;
        }
        if (seg.corrected) {
          html += `<span class="correction-added">${escapeHtml(seg.corrected)}</span>`;
        }
        html += `</span>`;
      }
    }

    html += `</div>`;

    for (const c of line.corrections) {
      html += `<div class="ann-note" data-note-for="${c.index}">`;
      html += `${escapeHtml(c.explanation)}`;
      html += `</div>`;
    }

    html += `</div>`;
  }

  return html;
}

/**
 * After buildHtml is inserted into the DOM, measure actual correction positions
 * and set margin-left on each annotation note to align with its correction.
 */
export function positionNotes(container) {
  for (const note of container.querySelectorAll('.ann-note')) {
    const index = note.dataset.noteFor;
    const line = note.closest('.ann-line');
    const textLine = line.querySelector('.ann-text-line');
    const correction = line.querySelector(`.correction-inline[data-correction-index="${index}"]`);

    if (!correction || !textLine) continue;

    const lineLeft = textLine.getBoundingClientRect().left;
    const corrLeft = correction.getBoundingClientRect().left;
    const containerW = textLine.clientWidth;
    const offsetPx = Math.round(corrLeft - lineLeft);

    // Ensure note has at least 200px (or full container if narrow) for readability
    const minNoteWidth = Math.min(200, containerW);
    const maxMargin = containerW - minNoteWidth;
    const marginPx = Math.min(offsetPx, maxMargin);
    const maxWidthPx = containerW - marginPx;

    note.style.marginLeft = `${marginPx}px`;
    note.style.maxWidth = `${maxWidthPx}px`;
  }
}
