;(() => {
  // Thin by design: report events as source offsets, apply what Swift sends.
  const root = document.getElementById('doc');
  const post = m => window.webkit.messageHandlers.marklight.postMessage(m);
  const purifyConfig = {
    ADD_ATTR: ['contenteditable'],
    FORBID_TAGS: ['style', 'form', 'textarea', 'select', 'button', 'iframe', 'frame', 'frameset', 'object', 'embed', 'base', 'meta', 'link'],
    RETURN_DOM_FRAGMENT: true,
  };

  // Top-level blocks and their source offsets. Offsets live here, not in the DOM,
  // so text above a block can change without touching it.
  const blocks = [];
  let version = 0;

  const local = el => el.dataset.src.split(':').map(Number);
  const blockOf = node => {
    let el = node && node.nodeType === 1 ? node : node && node.parentElement;
    while (el && el.parentElement !== root) el = el.parentElement;
    return el && el.parentElement === root ? el : null;
  };
  const range = el => local(el).map(n => n + blockOf(el)._base);

  function caretHolder(node) {
    const el = node.nodeType === 1 ? node : node.parentElement;
    return el ? el.closest('[data-caret]') : null;
  }

  function toSource(node, offset) {
    if (node === root) {
      const b = blocks[Math.min(offset, blocks.length - 1)];
      return b ? (offset >= blocks.length ? blockEnd(b) : toSource(b, 0)) : 0;
    }
    const block = blockOf(node);
    if (!block) return 0;
    const base = block._base;
    if (node.nodeType === 3) {
      const run = node.parentElement.closest('[data-run]');
      if (run) {
        const [s, e] = local(run);
        if ('atomic' in run.dataset) return base + (offset === 0 ? s : e);
        return base + s + offset;
      }
    } else if (node.nodeType === 1) {
      if ('caret' in node.dataset && node.querySelector('[data-run]') === null) return base + Number(node.dataset.caret);
      const kids = node.childNodes;
      for (let i = offset; i < kids.length; i++) {
        const k = kids[i];
        const run = k.nodeType === 1 && ('run' in k.dataset ? k : k.querySelector('[data-run]'));
        if (run) return base + local(run)[0];
      }
      for (let i = offset - 1; i >= 0; i--) {
        const k = kids[i];
        if (k.nodeType !== 1) continue;
        const inner = 'run' in k.dataset ? [k] : [...k.querySelectorAll('[data-run]')];
        if (inner.length) return base + local(inner[inner.length - 1])[1];
      }
    }
    const holder = caretHolder(node);
    return holder ? base + Number(holder.dataset.caret) : base;
  }

  const blockEnd = b => {
    const runs = b.querySelectorAll('[data-run]');
    return runs.length ? b._base + local(runs[runs.length - 1])[1] : b._base;
  };

  /// Index of the last block starting at or before `offset`.
  function blockIndexAt(offset) {
    let lo = 0, hi = blocks.length - 1, best = 0;
    while (lo <= hi) {
      const mid = (lo + hi) >> 1;
      if (blocks[mid]._base <= offset) { best = mid; lo = mid + 1; } else { hi = mid - 1; }
    }
    return best;
  }

  function toDOM(offset) {
    if (!blocks.length) return [root, 0];
    const block = blocks[blockIndexAt(offset)];
    const at = offset - block._base;
    const holders = block.querySelectorAll(`[data-caret="${at}"]`);
    for (const h of holders) if (!h.querySelector('[data-run]')) return [h, 0];
    let best = null;
    for (const run of block.querySelectorAll('[data-run]')) {
      const [s, e] = local(run);
      const atomic = 'atomic' in run.dataset;
      if (at >= s && at <= e) {
        if (!atomic && run.firstChild) return [run.firstChild, at - s];
        best = at === s ? [run, 'before'] : [run, 'after'];
      } else if (e <= at) {
        best = [run, 'after'];
      } else if (!best) {
        best = [run, 'before'];
      }
    }
    if (!best) {
      const holder = block.querySelector('[data-caret]');
      return holder ? [holder, 0] : [block, 0];
    }
    const [run, side] = best;
    const parent = run.parentNode;
    const index = [...parent.childNodes].indexOf(run);
    return [parent, side === 'before' ? index : index + 1];
  }

  function selection() {
    const s = getSelection();
    if (!s.rangeCount) return null;
    const r = s.getRangeAt(0);
    if (!root.contains(r.startContainer)) return null;
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

  // One edit in flight at a time. Typing that arrives meanwhile is merged, so a
  // slow parse batches keystrokes instead of queueing them.
  const queue = [];
  let inFlight = false;

  let waiting = [];
  let flying = [];

  function enqueue(m) {
    waiting.push(performance.now());
    const last = queue[queue.length - 1];
    if (m.type === 'input' && m.inputType === 'insertText' && !m.range && last && last.type === 'input' && last.inputType === 'insertText' && !last.range) {
      last.data += m.data;
      last.events = (last.events || 1) + 1;
    } else {
      queue.push(m);
    }
    pump();
  }

  function pump() {
    if (inFlight || !queue.length) return;
    const m = queue.shift();
    if (m.type === 'move') {
      const direction = { ArrowLeft: 'backward', ArrowRight: 'forward', ArrowUp: 'backward', ArrowDown: 'forward' }[m.key];
      const unit = m.key === 'ArrowUp' || m.key === 'ArrowDown' ? 'line'
        : m.meta ? 'lineboundary' : m.alt ? 'word' : 'character';
      if (direction) getSelection().modify(m.shift ? 'extend' : 'move', direction, unit);
      pump();
      return;
    }
    const sel = m.range || selection();
    if (!sel && m.type !== 'checkbox' && m.type !== 'undo') { pump(); return; }
    inFlight = true;
    flying = waiting;
    waiting = [];
    post({ ...m, v: version, start: sel ? sel[0] : 0, end: sel ? sel[1] : 0 });
  }

  let navigated = false;

  // WebKit clears the selection when the web view loses focus. Remember it, and
  // keep it pointing at the same text, so coming back puts the caret where it was.
  let remembered = null;
  let focused = false;
  document.addEventListener('selectionchange', () => {
    const sel = focused ? selection() : null;
    if (sel) remembered = sel;
  });
  root.addEventListener('blur', () => { focused = false; navigated = false; });
  root.addEventListener('focus', () => {
    // WebKit has already put the caret at the start by the time this runs.
    if (remembered && !navigated) select(remembered[0], remembered[1]);
    focused = true;
  });

  // Composition: the browser owns the DOM until it ends, and the buffer doesn't
  // change. Marked text can't be intercepted, so one block runs ahead of Swift.
  let composing = null;
  const trace = [];
  const compositionTypes = new Set(['insertCompositionText', 'deleteCompositionText', 'insertFromComposition', 'deleteByComposition']);

  root.addEventListener('compositionstart', () => {
    const sel = selection() || remembered || [0, 0];
    const block = blockOf(getSelection().anchorNode);
    trace.push(`start ${sel}`);
    // A composition over a selection deletes it first, possibly across blocks,
    // so keep a copy of every block it reaches for a cancel.
    const first = blockIndexAt(sel[0]), last = blockIndexAt(sel[1]);
    const saved = blocks.slice(first, last + 1).map(b => [b, b.cloneNode(true)]);
    composing = { range: sel, block, saved, deferred: [] };
  });

  /// WebKit's editing engine can unwrap or merge the top-level wrappers while
  /// composing. Put them back; Swift's next patch rebuilds what's inside.
  function reattach() {
    const whole = blocks.length === root.children.length && blocks.every((b, i) => root.children[i] === b);
    if (!whole) root.replaceChildren(...blocks);
  }

  root.addEventListener('compositionupdate', e => { trace.push(`update ${e.data}`); });

  root.addEventListener('compositionend', e => {
    const c = composing;
    composing = null;
    if (!c) return;
    trace.push(`end ${JSON.stringify(e.data)}`);
    reattach();
    if (!e.data) {
      // Cancelled: the browser may already have removed a selection.
      for (const [block, clone] of c.saved) morph(block, clone);
    }
    for (const m of c.deferred) marklight.patch(m);
    if (e.data) {
      navigated = false;
      enqueue({ type: 'input', inputType: 'insertText', data: e.data, composed: true, range: c.range, target: null, targetV: version });
    } else {
      select(c.range[0], c.range[1]);
    }
  });

  root.addEventListener('beforeinput', e => {
    if (compositionTypes.has(e.inputType) || e.isComposing || composing) {
      trace.push(`beforeinput ${e.inputType} ${e.data ?? ''}`);
      return;
    }
    e.preventDefault();
    navigated = false;
    if (e.inputType === 'historyUndo' || e.inputType === 'historyRedo') {
      enqueue({ type: 'undo', redo: e.inputType === 'historyRedo' });
      return;
    }
    const t = e.getTargetRanges()[0];
    const target = t ? [toSource(t.startContainer, t.startOffset), toSource(t.endContainer, t.endOffset)] : null;
    enqueue({ type: 'input', inputType: e.inputType, data: e.data, target, targetV: version, at: performance.now() });
  });

  // Flatten clipboard HTML to blocks of styled runs. Swift writes the Markdown.
  function blocksFrom(html) {
    const doc = new DOMParser().parseFromString(html, 'text/html');
    doc.body.replaceChildren(sanitize(doc.body.innerHTML));
    const out = [];
    const kindOf = {
      P: 'paragraph', DIV: 'paragraph', H1: 'h1', H2: 'h2', H3: 'h3', H4: 'h4', H5: 'h5', H6: 'h6',
      LI: 'bullet', BLOCKQUOTE: 'quote', PRE: 'code',
    };
    const inlineMarks = { B: 'strong', STRONG: 'strong', I: 'em', EM: 'em', CODE: 'code', S: 'strike', DEL: 'strike' };
    let current = null;
    const flush = () => { if (current && current.runs.some(r => r.text.trim())) out.push(current); current = null; };
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
    return out;
  }

  const sanitize = html => globalThis.DOMPurify.sanitize(html, purifyConfig);

  // Offsets are trusted input to Swift, so raw HTML from the document can't carry them.
  function disarm(scope) {
    for (const block of scope.querySelectorAll('[data-raw]')) {
      for (const el of block.querySelectorAll('*')) {
        for (const a of ['data-src', 'data-run', 'data-atomic', 'data-caret', 'contenteditable']) el.removeAttribute(a);
        if (el.matches('input')) el.setAttribute('disabled', '');
      }
    }
  }

  function makeBlock(html, base) {
    const el = document.createElement('div');
    el.append(sanitize(html));
    disarm(el);
    el._base = base;
    return el;
  }

  /// Turns live node `a` into `b`, keeping every node it can.
  function morph(a, b) {
    for (const { name } of [...a.attributes]) if (!b.hasAttribute(name)) a.removeAttribute(name);
    for (const { name, value } of [...b.attributes]) if (a.getAttribute(name) !== value) a.setAttribute(name, value);
    // Match from the end first, so inserting one list item leaves the rest alone.
    let aEnd = a.lastChild;
    let bEnd = b.lastChild;
    const same = (x, y) => x.nodeType === y.nodeType && x.nodeName === y.nodeName && x.textContent === y.textContent;
    while (aEnd && bEnd && aEnd.previousSibling && bEnd.previousSibling && same(aEnd, bEnd)) {
      const ap = aEnd.previousSibling, bp = bEnd.previousSibling;
      if (aEnd.nodeType === 1) morph(aEnd, bEnd);
      bEnd.remove();
      aEnd = ap;
      bEnd = bp;
    }
    const stop = aEnd ? aEnd.nextSibling : null;
    let ac = a.firstChild;
    let bc = b.firstChild;
    while (bc) {
      const next = bc.nextSibling;
      if (!ac || ac === stop) {
        a.insertBefore(bc, stop);
      } else if (ac.nodeType === bc.nodeType && ac.nodeName === bc.nodeName) {
        if (ac.nodeType === 1) morph(ac, bc);
        else if (ac.nodeValue !== bc.nodeValue) ac.nodeValue = bc.nodeValue;
        ac = ac.nextSibling;
      } else {
        const after = ac.nextSibling;
        a.replaceChild(bc, ac);
        ac = after;
      }
      bc = next;
    }
    while (ac && ac !== stop) {
      const after = ac.nextSibling;
      a.removeChild(ac);
      ac = after;
    }
  }

  /// The first block showing at the top of the viewport.
  function scrollAnchor() {
    let lo = 0, hi = blocks.length - 1, found = null;
    while (lo <= hi) {
      const mid = (lo + hi) >> 1;
      if (blocks[mid].getBoundingClientRect().bottom > 0) { found = mid; hi = mid - 1; } else { lo = mid + 1; }
    }
    return found === null ? [] : blocks.slice(found, found + 8).map(el => [el, el.getBoundingClientRect().top]);
  }

  function keepCaretVisible() {
    const s = getSelection();
    if (!s.rangeCount) return;
    let r = s.getRangeAt(0).getBoundingClientRect();
    if (r.top === 0 && r.bottom === 0) {
      const n = s.anchorNode;
      r = (n.nodeType === 1 ? n : n.parentElement).getBoundingClientRect();
    }
    if (r.bottom > innerHeight) window.scrollBy(0, r.bottom - innerHeight + 8);
    else if (r.top < 0) window.scrollBy(0, r.top - 8);
  }

  let watched = null;
  const counters = { patches: 0, morphed: 0, replaced: 0, patchMs: [], latency: [] };

  const marklight = {
    load(list, v, start, end) {
      version = v;
      blocks.length = 0;
      root.replaceChildren(...list.map(b => {
        const el = makeBlock(b.html, b.base);
        blocks.push(el);
        return el;
      }));
      root.focus();
      if (start !== null) select(start, end);
    },

    /// `m`: {v, from, remove, list, delta, local, caret, edits}
    patch(m) {
      const t0 = performance.now();
      const carryEdits = o => m.edits.reduce((x, [lo, hi, n]) => x >= hi ? x + n - (hi - lo) : x > lo ? lo + n : x, o);
      if (composing) {
        composing.range = composing.range.map(carryEdits);
        const at = blocks.indexOf(composing.block);
        const reaches = at >= m.from && at < m.from + m.remove;
        if (reaches || composing.deferred.length || !composing.block || !composing.block.isConnected) {
          // Don't touch the block being composed. Catch up when composition ends.
          composing.deferred.push({ ...m, list: m.list });
          version = m.v;
          return;
        }
      }
      const remoteSel = composing ? null : selection();
      const hadFocus = remoteSel !== null;
      const sel = getSelection();
      const caretBlock = hadFocus ? blockOf(sel.anchorNode) : null;
      const anchors = m.local ? [] : scrollAnchor();

      const live = blocks.slice(m.from, m.from + m.remove);
      const made = m.list.map(b => makeBlock(b.html, b.base));
      const paired = Math.min(live.length, made.length);
      const keep = [];
      for (let i = 0; i < paired; i++) {
        morph(live[i], made[i]);
        live[i]._base = made[i]._base;
        keep.push(live[i]);
        counters.morphed++;
      }
      const before = blocks[m.from + m.remove] || null;
      for (let i = paired; i < live.length; i++) { live[i].remove(); counters.replaced++; }
      for (let i = paired; i < made.length; i++) {
        root.insertBefore(made[i], before);
        keep.push(made[i]);
        counters.replaced++;
      }
      blocks.splice(m.from, m.remove, ...keep);
      if (m.delta) for (let i = m.from + keep.length; i < blocks.length; i++) blocks[i]._base += m.delta;
      version = m.v;

      const carry = o => m.edits.reduce((x, [lo, hi, n]) => x >= hi ? x + n - (hi - lo) : x > lo ? lo + n : x, o);
      if (remembered) remembered = remembered.map(carry);
      const touched = caretBlock !== null && (live.includes(caretBlock) || !caretBlock.isConnected);
      if (composing) {
        // The browser's selection is the composition. Leave it alone.
      } else if (m.local && !navigated && m.caret) {
        root.focus();
        select(m.caret[0], m.caret[1]);
        keepCaretVisible();
      } else if (hadFocus && (touched || m.local)) {
        // Swift sends what happened, so the caret moves with the text around it.
        select(carry(remoteSel[0]), carry(remoteSel[1]));
      }
      for (const [el, top] of anchors) {
        if (el.isConnected) {
          const moved = el.getBoundingClientRect().top - top;
          if (moved) window.scrollBy(0, moved);
          break;
        }
      }
      counters.patches++;
      const now = performance.now();
      counters.patchMs.push(now - t0);
      if (m.local) {
        for (const at of flying) counters.latency.push(now - at);
        flying = [];
      }
    },

    /// Swift has finished with the message in flight.
    done(v) {
      if (v !== undefined && v > version) version = v;
      inFlight = false;
      pump();
    },

    select, selection,
    trace: () => trace.splice(0),
    composing: () => composing !== null,
    version: () => version,
    text: () => root.textContent,
    idle: () => !inFlight && queue.length === 0,
    selectBlock(n, at) {
      const [s] = range(blocks[n].querySelector('[data-src]'));
      select(s + at, s + at);
      return s + at;
    },
    caretNode() { return tag(getSelection().anchorNode); },
    caretOffset() { return getSelection().anchorOffset; },
    rectOf(offset) {
      const box = [...root.querySelectorAll('input[type=checkbox]')].find(b => { const [s, e] = range(b); return s <= offset && offset <= e; });
      if (!box) return null;
      const r = box.getBoundingClientRect();
      return [r.left + r.width / 2, r.top + r.height / 2];
    },
    rectAt(offset) {
      const [node, at] = toDOM(offset);
      const r = document.createRange();
      r.setStart(node, at);
      r.setEnd(node, at + 1);
      const box = r.getBoundingClientRect();
      return [box.left + 1, box.top + box.height / 2];
    },
    selectAll() { getSelection().selectAllChildren(root); },
    paste(plain, html) {
      const d = new DataTransfer();
      d.setData('text/plain', plain);
      if (html) d.setData('text/html', html);
      root.dispatchEvent(new ClipboardEvent('paste', { clipboardData: d, bubbles: true, cancelable: true }));
    },

    // Measurement only.
    watch() {
      const seen = { added: 0, removed: 0, text: 0, attrs: 0 };
      const count = list => {
        for (const r of list) {
          if (r.type === 'childList') { seen.added += r.addedNodes.length; seen.removed += r.removedNodes.length; }
          else if (r.type === 'characterData') seen.text++;
          else seen.attrs++;
        }
      };
      const o = new MutationObserver(count);
      o.observe(root, { subtree: true, childList: true, characterData: true, attributes: true });
      marklight.stats = () => {
        count(o.takeRecords());
        const out = { ...seen, patches: counters.patches, morphed: counters.morphed, replaced: counters.replaced, patchMs: counters.patchMs.slice(), latency: counters.latency.slice() };
        Object.assign(seen, { added: 0, removed: 0, text: 0, attrs: 0 });
        Object.assign(counters, { patches: 0, morphed: 0, replaced: 0, patchMs: [], latency: [] });
        return out;
      };
    },
    /// Live DOM against a fresh render: same nodes, same offsets.
    verify(list) {
      if (list.length !== blocks.length) return `block count ${blocks.length} vs ${list.length}`;
      for (let i = 0; i < list.length; i++) {
        const fresh = makeBlock(list[i].html, list[i].base);
        if (!fresh.isEqualNode(blocks[i])) return `block ${i} differs: ${blocks[i].innerHTML.slice(0, 120)} vs ${fresh.innerHTML.slice(0, 120)}`;
        if (blocks[i]._base !== list[i].base) return `block ${i} base ${blocks[i]._base} vs ${list[i].base}`;
      }
      return null;
    },
    /// Tags every element so a later check can tell which nodes survived.
    tagAll() {
      let n = 0;
      for (const el of root.querySelectorAll('*')) el._tag = ++n;
      for (const b of blocks) b._blockTag = ++n;
      return n;
    },
    /// Elements outside block index `skip` that are no longer the same node.
    untagged(skip) {
      let lost = 0, total = 0;
      blocks.forEach((b, i) => {
        if (i === skip) return;
        total++;
        if (b._blockTag === undefined) lost++;
        for (const el of b.querySelectorAll('*')) { total++; if (el._tag === undefined) lost++; }
      });
      return [lost, total];
    },
    scroll() { return [scrollY, document.documentElement.scrollHeight]; },
    scrollTo(y) { window.scrollTo(0, y); },
    watchVisible() {
      const a = scrollAnchor()[0];
      watched = a[0];
      return a[1];
    },
    watchedTop() { return watched.isConnected ? watched.getBoundingClientRect().top : null; },
    focusRoot() { root.focus(); },
    blockCount: () => blocks.length,
    runTag() {
      const n = getSelection().anchorNode;
      return n ? (n.nodeType === 1 ? n : n.parentElement)._tag || 0 : 0;
    },
  };

  function tag(node) { const el = node.nodeType === 1 ? node : node.parentElement; return el._tag || 0; }

  root.addEventListener('paste', e => {
    e.preventDefault();
    const html = e.clipboardData.getData('text/html');
    const plain = e.clipboardData.getData('text/plain');
    enqueue({ type: 'paste', plain, blocks: html ? blocksFrom(html) : null });
  });

  // WebKit doesn't deliver click to a form control inside an editable root, and
  // the checkbox shouldn't take focus or move the caret anyway.
  root.addEventListener('mousedown', e => {
    navigated = true;
    if (e.target.matches('input[type=checkbox]')) {
      e.preventDefault();
      enqueue({ type: 'checkbox', checkbox: range(e.target)[0] });
    }
  });

  const navigation = new Set(['ArrowLeft', 'ArrowRight', 'ArrowUp', 'ArrowDown', 'Home', 'End', 'PageUp', 'PageDown']);

  root.addEventListener('keydown', e => {
    // keyCode 229 covers the key that ends a composition, which can arrive after
    // compositionend with isComposing already false.
    if (e.isComposing || e.keyCode === 229 || composing) return;
    if (navigation.has(e.key)) {
      // With an edit outstanding the DOM is behind the text, and the browser would
      // move the caret from the wrong place. Replay the move after the edit lands.
      if (inFlight || queue.length) {
        e.preventDefault();
        enqueue({ type: 'move', key: e.key, shift: e.shiftKey, alt: e.altKey, meta: e.metaKey });
        return;
      }
      navigated = true;
    }
    const plain = !e.metaKey && !e.altKey && !e.ctrlKey;
    // WebKit sends no beforeinput for Backspace at the start of the document, or
    // for a line break as opposed to a paragraph, so these start here.
    if (plain && (e.key === 'Backspace' || (e.key === 'Enter' && e.shiftKey))) {
      e.preventDefault();
      navigated = false;
      enqueue({ type: 'input', inputType: e.key === 'Enter' ? 'insertLineBreak' : 'deleteContentBackward', data: null, target: null, targetV: version });
      return;
    }
    if (!e.metaKey) return;
    if (e.key === 'z' || e.key === 'Z') {
      e.preventDefault();
      navigated = false;
      enqueue({ type: 'undo', redo: e.shiftKey });
      return;
    }
    const kind = { b: 'strong', i: 'em', e: 'code' }[e.key];
    if (!kind) return;
    e.preventDefault();
    navigated = false;
    enqueue({ type: 'toggle', kind });
  });

  globalThis.marklight = marklight;
  post({ type: 'ready' });
})();
