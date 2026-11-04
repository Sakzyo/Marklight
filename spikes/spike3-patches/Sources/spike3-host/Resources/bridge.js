;(() => {
  // Thin by design: report events as source offsets, apply what Swift sends.
  const root = document.getElementById('doc');
  const send = m => window.webkit.messageHandlers.marklight.postMessage(m);
  const purifyConfig = {
    ADD_ATTR: ['contenteditable'],
    FORBID_TAGS: ['style', 'form', 'textarea', 'select', 'button', 'iframe', 'frame', 'frameset', 'object', 'embed', 'base', 'meta', 'link'],
  };

  const range = el => el.dataset.src.split(':').map(Number);
  const runs = () => [...root.querySelectorAll('[data-run]')];

  function caretHolder(node) {
    const el = node.nodeType === 1 ? node : node.parentElement;
    return el ? el.closest('[data-caret]') : null;
  }

  function toSource(node, offset) {
    if (node.nodeType === 3) {
      const run = node.parentElement.closest('[data-run]');
      if (run) {
        const [s, e] = range(run);
        if ('atomic' in run.dataset) return offset === 0 ? s : e;
        return s + offset;
      }
    } else if (node.nodeType === 1) {
      if ('caret' in node.dataset && node.querySelector('[data-run]') === null) return Number(node.dataset.caret);
      const kids = node.childNodes;
      for (let i = offset; i < kids.length; i++) {
        const k = kids[i];
        const run = k.nodeType === 1 && ('run' in k.dataset ? k : k.querySelector('[data-run]'));
        if (run) return range(run)[0];
      }
      for (let i = offset - 1; i >= 0; i--) {
        const k = kids[i];
        if (k.nodeType !== 1) continue;
        const inner = 'run' in k.dataset ? [k] : [...k.querySelectorAll('[data-run]')];
        if (inner.length) return range(inner[inner.length - 1])[1];
      }
    }
    const holder = caretHolder(node);
    return holder ? Number(holder.dataset.caret) : 0;
  }

  function toDOM(offset) {
    const placeholder = root.querySelector(`[data-caret="${offset}"]:not(:has([data-run]))`);
    if (placeholder) return [placeholder, 0];
    let best = null;
    for (const run of runs()) {
      const [s, e] = range(run);
      const atomic = 'atomic' in run.dataset;
      if (offset >= s && offset <= e) {
        if (!atomic && run.firstChild) return [run.firstChild, offset - s];
        best = offset === s ? [run, 'before'] : [run, 'after'];
      } else if (e <= offset) {
        best = [run, 'after'];
      } else if (!best) {
        best = [run, 'before'];
      }
    }
    if (!best) return [root, 0];
    const [run, side] = best;
    const parent = run.parentNode;
    const index = [...parent.childNodes].indexOf(run);
    return [parent, side === 'before' ? index : index + 1];
  }

  function selection() {
    const s = getSelection();
    if (!s.rangeCount) return null;
    const r = s.getRangeAt(0);
    return [toSource(r.startContainer, r.startOffset), toSource(r.endContainer, r.endOffset)];
  }

  function select(start, end) {
    const s = getSelection();
    const r = document.createRange();
    const [a, ao] = toDOM(start);
    r.setStart(a, ao);
    if (end !== start) {
      const [b, bo] = toDOM(end);
      r.setEnd(b, bo);
    } else {
      r.collapse(true);
    }
    s.removeAllRanges();
    s.addRange(r);
  }

  root.addEventListener('beforeinput', e => {
    if (e.isComposing || e.inputType === 'insertCompositionText') return; // Spike 5
    e.preventDefault();
    const sel = selection();
    if (!sel) return;
    const t = e.getTargetRanges()[0];
    const target = t ? [toSource(t.startContainer, t.startOffset), toSource(t.endContainer, t.endOffset)] : null;
    send({ type: 'input', inputType: e.inputType, data: e.data, start: sel[0], end: sel[1], target });
  });

  // Flatten clipboard HTML to blocks of styled runs. Swift writes the Markdown.
  function blocksFrom(html) {
    const doc = new DOMParser().parseFromString(purify(html), 'text/html');
    const blocks = [];
    const kindOf = {
      P: 'paragraph', DIV: 'paragraph', H1: 'h1', H2: 'h2', H3: 'h3', H4: 'h4', H5: 'h5', H6: 'h6',
      LI: 'bullet', BLOCKQUOTE: 'quote', PRE: 'code',
    };
    const inlineMarks = { B: 'strong', STRONG: 'strong', I: 'em', EM: 'em', CODE: 'code', S: 'strike', DEL: 'strike' };
    let current = null;
    const flush = () => { if (current && current.runs.some(r => r.text.trim())) blocks.push(current); current = null; };
    function walk(node, marks, href, kind) {
      for (const n of node.childNodes) {
        if (n.nodeType === 3) {
          const text = kind === 'code' ? n.nodeValue : n.nodeValue.replace(/\s+/g, ' ');
          if (!text) continue;
          current = current || { kind, runs: [] };
          current.runs.push({ text, marks, href });
        } else if (n.nodeType === 1) {
          if (kindOf[n.tagName]) {
            flush();
            const k = n.tagName === 'LI' && n.parentElement.tagName === 'OL' ? 'ordered' : kindOf[n.tagName];
            walk(n, marks, href, k);
            flush();
          } else if (n.tagName === 'BR') {
            flush();
          } else if (n.tagName === 'UL' || n.tagName === 'OL') {
            walk(n, marks, href, kind);
          } else {
            const m = inlineMarks[n.tagName];
            const next = m && !marks.includes(m) ? [...marks, m] : marks;
            walk(n, next, n.tagName === 'A' ? n.getAttribute('href') : href, kind);
          }
        }
      }
    }
    walk(doc.body, [], null, 'paragraph');
    flush();
    return blocks;
  }

  function purify(html) { return globalThis.DOMPurify.sanitize(html, purifyConfig); }

  root.addEventListener('paste', e => {
    e.preventDefault();
    const sel = selection();
    const html = e.clipboardData.getData('text/html');
    const plain = e.clipboardData.getData('text/plain');
    send({ type: 'paste', start: sel[0], end: sel[1], plain, blocks: html ? blocksFrom(html) : null });
  });

  // WebKit doesn't deliver click to a form control inside an editable root, and
  // the checkbox shouldn't take focus or move the caret anyway.
  root.addEventListener('mousedown', e => {
    if (e.target.matches('input[type=checkbox]')) {
      e.preventDefault();
      const sel = selection() || [0, 0];
      send({ type: 'checkbox', at: range(e.target)[0], start: sel[0], end: sel[1] });
    }
  });

  root.addEventListener('keydown', e => {
    if (e.isComposing) return;
    const plain = !e.metaKey && !e.altKey && !e.ctrlKey;
    // WebKit sends no beforeinput for Backspace at the start of the document, or
    // for a line break as opposed to a paragraph, so these start here.
    if (plain && (e.key === 'Backspace' || (e.key === 'Enter' && e.shiftKey))) {
      e.preventDefault();
      const sel = selection();
      if (sel) send({ type: 'input', inputType: e.key === 'Enter' ? 'insertLineBreak' : 'deleteContentBackward', data: null, start: sel[0], end: sel[1], target: null });
      return;
    }
    if (!e.metaKey) return;
    const kind = { b: 'strong', i: 'em', e: 'code' }[e.key];
    if (!kind) return;
    e.preventDefault();
    const sel = selection();
    send({ type: 'toggle', kind, start: sel[0], end: sel[1] });
  });

  globalThis.marklight = {
    update(html, start, end) {
      root.innerHTML = purify(html);
      root.focus();
      select(start, end);
    },
    select, selection,
    text: () => root.textContent,
    rectOf(offset) {
      const box = [...root.querySelectorAll('input[type=checkbox]')].find(b => { const [s, e] = range(b); return s <= offset && offset <= e; });
      if (!box) return null;
      const r = box.getBoundingClientRect();
      return [r.left + r.width / 2, r.top + r.height / 2];
    },
    paste(plain, html) {
      const d = new DataTransfer();
      d.setData('text/plain', plain);
      if (html) d.setData('text/html', html);
      root.dispatchEvent(new ClipboardEvent('paste', { clipboardData: d, bubbles: true, cancelable: true }));
    },
  };
  send({ type: 'ready' });
})();
