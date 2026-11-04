;(() => {
  // Thin by design: Swift renders and decides. This puts blocks in the DOM, keeps
  // the scroll position still, and reports where the user clicked as source offsets.
  // It runs in an isolated content world. The page's own world can't see any of it.
  const root = document.getElementById('doc');
  const post = m => window.webkit.messageHandlers.marklight.postMessage(m);

  const purifyConfig = {
    FORBID_TAGS: ['style', 'form', 'textarea', 'select', 'button', 'iframe', 'frame', 'frameset', 'object', 'embed', 'base', 'meta', 'link'],
    FORBID_ATTR: ['action', 'formaction'],
    RETURN_DOM_FRAGMENT: true,
  };
  const sanitize = html => globalThis.DOMPurify.sanitize(html, purifyConfig);

  // Top-level blocks, in order. A block's source offset is a property here, not in
  // the DOM, so text above a block can change without touching it.
  let blocks = [];
  let version = 0;

  const local = el => el.dataset.src.split(':').map(Number);

  function blockOf(node) {
    let el = node && node.nodeType === 1 ? node : node && node.parentElement;
    while (el && el.parentElement !== root) el = el.parentElement;
    return el;
  }

  // Raw HTML arrives as text, so it can't close its holder and escape into the
  // block. It's sanitized here, and nothing in it may claim a source offset.
  const reserved = ['data-src', 'data-run', 'data-atomic', 'data-caret', 'data-raw', 'contenteditable'];

  function expandRaw(scope) {
    for (const holder of scope.querySelectorAll('[data-raw]')) {
      holder.replaceChildren(sanitize(holder.textContent));
      for (const el of holder.querySelectorAll('*')) {
        for (const name of reserved) el.removeAttribute(name);
        if (el.matches('input')) el.setAttribute('disabled', '');
      }
    }
  }

  function makeBlock(html, base) {
    const el = document.createElement('div');
    el.append(sanitize(html));
    expandRaw(el);
    el._base = base;
    return el;
  }

  /// Turns live node `a` into `b`, keeping every node it can.
  function morph(a, b) {
    for (const { name } of [...a.attributes]) if (!b.hasAttribute(name)) a.removeAttribute(name);
    for (const { name, value } of [...b.attributes]) if (a.getAttribute(name) !== value) a.setAttribute(name, value);

    // Pair children from the end first, so one new list item leaves the rest alone.
    const alike = (x, y) => x.nodeType === y.nodeType && x.nodeName === y.nodeName && x.textContent === y.textContent;
    let aLast = a.lastChild;
    let bLast = b.lastChild;
    while (aLast && bLast && aLast.previousSibling && bLast.previousSibling && alike(aLast, bLast)) {
      const aPrevious = aLast.previousSibling, bPrevious = bLast.previousSibling;
      if (aLast.nodeType === 1) morph(aLast, bLast);
      bLast.remove();
      aLast = aPrevious;
      bLast = bPrevious;
    }

    const stop = aLast ? aLast.nextSibling : null;
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

  /// Index of the last block starting at or before `offset`.
  function blockIndexAt(offset) {
    let lo = 0, hi = blocks.length - 1, best = 0;
    while (lo <= hi) {
      const mid = (lo + hi) >> 1;
      if (blocks[mid]._base <= offset) { best = mid; lo = mid + 1; } else { hi = mid - 1; }
    }
    return best;
  }

  // WebKit has no scroll anchoring, so a patch above the viewport would move what
  // the reader is looking at. These are the elements at the top of the viewport,
  // innermost first, so an edit inside a long list or table holds still too. The
  // next few blocks are there in case the patch removes those.
  function scrollAnchors() {
    let lo = 0, hi = blocks.length - 1, first = null;
    while (lo <= hi) {
      const mid = (lo + hi) >> 1;
      if (blocks[mid].getBoundingClientRect().bottom > 0) { first = mid; hi = mid - 1; } else { lo = mid + 1; }
    }
    if (first === null) return [];
    const inner = [];
    let el = document.elementFromPoint(root.getBoundingClientRect().left + 40, 1);
    while (el && el !== root && root.contains(el)) {
      inner.push(el);
      el = el.parentElement;
    }
    return [...inner, ...blocks.slice(first, first + 8)].map(el => [el, el.getBoundingClientRect().top]);
  }

  function restoreScroll(anchors) {
    for (const [el, top] of anchors) {
      if (!el.isConnected) continue;
      const moved = el.getBoundingClientRect().top - top;
      if (moved) window.scrollBy(0, moved);
      return;
    }
  }

  function toSource(node, offset) {
    if (node === root) {
      if (offset < blocks.length) return blocks[offset]._base;
      const last = blocks[blocks.length - 1];
      return last ? last._base + local(last.firstElementChild)[1] : 0;
    }
    const block = blockOf(node);
    if (!block) return 0;
    const base = block._base;
    if (node.nodeType === 3) {
      const run = node.parentElement.closest('[data-run]');
      if (run) {
        const [start, end] = local(run);
        if ('atomic' in run.dataset) return base + (offset === 0 ? start : end);
        return base + start + offset;
      }
    } else if (node.nodeType === 1) {
      // Between children: the nearest run after, or else the nearest before.
      const kids = node.childNodes;
      for (let i = offset; i < kids.length; i++) {
        const kid = kids[i];
        const run = kid.nodeType === 1 && ('run' in kid.dataset ? kid : kid.querySelector('[data-run]'));
        if (run) return base + local(run)[0];
      }
      for (let i = offset - 1; i >= 0; i--) {
        const kid = kids[i];
        if (kid.nodeType !== 1) continue;
        const runs = 'run' in kid.dataset ? [kid] : [...kid.querySelectorAll('[data-run]')];
        if (runs.length) return base + local(runs[runs.length - 1])[1];
      }
    }
    const el = node.nodeType === 1 ? node : node.parentElement;
    const holder = el.closest('[data-caret]');
    if (holder) return base + Number(holder.dataset.caret);
    const owner = el.closest('[data-src]'); // raw HTML has no offsets of its own
    return base + (owner ? local(owner)[0] : 0);
  }

  function selection(event) {
    const s = getSelection();
    let range = s.rangeCount ? s.getRangeAt(0) : null;
    // WebKit may not set a selection for a click on content that can't be edited.
    if (!range && event) range = document.caretRangeFromPoint(event.clientX, event.clientY);
    if (!range || !root.contains(range.startContainer) || !root.contains(range.endContainer)) return null;
    return [toSource(range.startContainer, range.startOffset), toSource(range.endContainer, range.endOffset)];
  }

  // Not `selectionchange`, which also fires when a patch replaces selected nodes.
  // Deferred because a click inside a selection clears it only after `mouseup`.
  function report(event) {
    setTimeout(() => {
      const s = selection(event);
      if (s) post({ type: 'selection', v: version, start: s[0], end: s[1] });
    }, 0);
  }

  document.addEventListener('mouseup', report);
  document.addEventListener('keyup', e => {
    if (e.shiftKey && e.key.startsWith('Arrow')) report();
  });

  const slug = text => text.trim().toLowerCase().replace(/[^\p{L}\p{M}\p{N}\p{Pc}\- ]/gu, '').replace(/ /g, '-');

  // Resolved here rather than stored as `id`s, which would depend on the headings
  // above a block and so change its HTML when they do.
  function anchorTarget(name) {
    const named = document.getElementById(name) || document.getElementsByName(name)[0];
    if (named && root.contains(named)) return named;
    const seen = new Map();
    const wanted = name.toLowerCase();
    for (const heading of root.querySelectorAll('h1, h2, h3, h4, h5, h6')) {
      const text = slug(heading.textContent);
      const count = seen.get(text) || 0;
      seen.set(text, count + 1);
      if ((count ? `${text}-${count}` : text) === wanted) return heading;
    }
    return null;
  }

  /// The fragment of a link into this document, or null for a link anywhere else.
  function fragment(link) {
    try {
      const url = new URL(link.getAttribute('href'), document.baseURI);
      const here = url.protocol === location.protocol && url.host === location.host && url.pathname === location.pathname;
      return here && url.hash.length > 1 ? decodeURIComponent(url.hash.slice(1)) : null;
    } catch {
      return null;
    }
  }

  document.addEventListener('click', e => {
    const link = e.target.closest && e.target.closest('a[href]');
    const name = link && fragment(link);
    if (!name) return;
    e.preventDefault();
    const target = anchorTarget(name);
    if (target) target.scrollIntoView();
  });

  globalThis.marklight = {
    /// Shows a whole document. `list` is `[{html, base}]`.
    load(list, v) {
      const holder = document.createDocumentFragment();
      const made = list.map(b => holder.appendChild(makeBlock(b.html, b.base)));
      root.replaceChildren(holder);
      blocks = made;
      version = v;
    },

    /// Replaces `remove` blocks at `from` with `list`, keeping every node it can.
    patch(m) {
      const anchors = scrollAnchors();
      const live = blocks.slice(m.from, m.from + m.remove);
      const after = blocks.slice(m.from + m.remove);
      const made = m.list.map(b => makeBlock(b.html, b.base));
      const paired = Math.min(live.length, made.length);
      const kept = [];
      for (let i = 0; i < paired; i++) {
        morph(live[i], made[i]);
        live[i]._base = made[i]._base;
        kept.push(live[i]);
      }
      for (const el of live.slice(paired)) el.remove();
      for (const el of made.slice(paired)) {
        root.insertBefore(el, after[0] || null);
        kept.push(el);
      }
      if (m.delta) for (const el of after) el._base += m.delta;
      blocks = blocks.slice(0, m.from).concat(kept, after);
      version = m.v;
      restoreScroll(anchors);
    },

    /// Scrolls to what's at `offset`, unless some of it is already showing.
    reveal(offset) {
      if (!blocks.length) return;
      const block = blocks[blockIndexAt(offset)];
      const at = offset - block._base;
      const covers = el => {
        if (!el.dataset.src) return false;
        const [start, end] = local(el);
        return start <= at && at <= end;
      };
      let el = block.firstElementChild;
      for (let inner = el; inner; inner = [...el.children].find(covers)) el = inner;
      const box = el.getBoundingClientRect();
      if (box.bottom > 0 && box.top < innerHeight) return;
      el.scrollIntoView({ block: box.height < innerHeight ? 'center' : 'start' });
    },
  };

  post({ type: 'ready' });
})();
