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
        // WebKit treats this CSS property as an editable region even without
        // an HTML contenteditable attribute.
        el.style?.removeProperty('-webkit-user-modify');
        if (el.matches('input')) el.setAttribute('disabled', '');
      }
    }
  }

  function makeBlock(html, base) {
    const el = document.createElement('div');
    el.append(sanitize(html));
    // Only renderer-owned elements have been unpacked here. A raw descendant
    // cannot declare itself editable or manufacture an offset.
    for (const item of el.querySelectorAll('pre,table,hr,img,input,.opaque,.inline-html,[data-raw]')) {
      item.contentEditable = 'false';
    }
    for (const leaf of el.querySelectorAll('[data-caret]:empty')) {
      if (!leaf.closest('[contenteditable="false"]')) leaf.append(document.createElement('br'));
    }
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
    const column = root.getBoundingClientRect();
    let el = document.elementFromPoint(column.left + column.width / 2, 1);
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

  // Resolve a source offset within just one block. At a delimiter, prefer the
  // nearest actual text position. An empty leaf has its own caret before its br.
  function position(offset) {
    if (!blocks.length) return [root, 0];
    const block = blocks[blockIndexAt(offset)], at = offset - block._base;
    const empty = block.querySelector(`[data-caret="${at}"]`);
    if (empty) return [empty, 0];
    let closest = [block, 0], distance = Infinity;
    for (const run of block.querySelectorAll('[data-run]')) {
      const [lo, hi] = local(run);
      const node = run.firstChild;
      if (node?.nodeType === 3 && !run.hasAttribute('data-atomic') && lo <= at && at <= hi) {
        return [node, at - lo];
      }
      for (const end of [false, true]) {
        const d = Math.abs(at - (end ? hi : lo));
        if (d >= distance) continue;
        distance = d;
        if (node?.nodeType === 3 && !run.closest('[contenteditable="false"]')) {
          closest = [node, end ? node.length : 0];
        } else {
          closest = [run.parentNode, Array.prototype.indexOf.call(run.parentNode.childNodes, run) + Number(end)];
        }
      }
    }
    return closest;
  }

  let remembered = null;
  function select(start, end) {
    const [a, ao] = position(start), [b, bo] = start === end ? [a, ao] : position(end);
    getSelection().setBaseAndExtent(a, ao, b, bo);
    remembered = [start, end];
  }

  const pending = [];
  let inFlight = false, movedSinceInput = false, clicked = false;
  let composing = null;

  function input(inputType, data = null, target = null, range = null) {
    return {type: 'input', inputType, data, target, targetV: version, composed: range !== null, range};
  }

  // AppKit can deliver the first key after native refocus before WebKit
  // delivers its DOM focus event. At that instant the live range may be zero.
  function returningCaret() {
    return !clicked && !document.hasFocus() && document.activeElement === root ? remembered : null;
  }

  function sendNext() {
    while (!inFlight && pending.length) {
      const event = pending.shift();
      if (event.move) {
        replayMove(event);
        continue;
      }
      let message;
      if (event.type === 'undo') {
        message = {...event, v: version};
      } else {
        const {fixed, ...fields} = event;
        const [start, end] = fixed?.range || event.range || returningCaret() || selection() || remembered || [0, 0];
        message = {...fields, v: fixed?.version ?? version, start, end};
      }
      inFlight = true;
      movedSinceInput = false;
      post(message);
    }
  }

  function enqueue(event) {
    const last = pending.at(-1);
    // A target range is meaningful for deletes and replacement text. For
    // ordinary adjacent typing Swift uses the caret from the preceding reply.
    if (last?.inputType === 'insertText' && event.inputType === 'insertText' && !last.composed && !event.composed && !last.fixed && !event.fixed) {
      last.data += event.data;
    } else {
      pending.push(event);
    }
    sendNext();
  }

  // A focusable link or summary in read-only HTML can receive keydown with
  // no live selection. Report its own uneditable source range to Swift. Never
  // use a remembered caret from an unrelated editable paragraph in that case.
  function protectedRange(e) {
    const node = getSelection().focusNode;
    const owner = [e.target, document.activeElement, node?.nodeType === 1 ? node : node?.parentElement].map(el =>
      el?.closest?.('[contenteditable="false"]')).find(el => el && root.contains(el));
    if (!owner) return null;
    const block = blockOf(owner);
    const range = block && owner.hasAttribute('data-src') ? local(owner).map(at => block._base + at) : [0, 0];
    return {range, version};
  }

  function submit(e, event) {
    const fixed = protectedRange(e);
    if (fixed) {
      event.fixed = fixed;
      event.target = fixed.range;
    }
    enqueue(event);
  }

  document.addEventListener('selectionchange', () => {
    // WebKit leaves activeElement at the editing host while another native
    // pane has focus, then reports a selection at zero. Keep the carried caret.
    if (!composing && document.hasFocus() && document.activeElement === root) remembered = selection() || remembered;
  });
  root.addEventListener('mousedown', () => { clicked = true; movedSinceInput = true; });
  document.addEventListener('mouseup', () => { clicked = false; });
  root.addEventListener('focus', () => {
    if (remembered && !clicked && !composing) select(...remembered);
  });

  // Native input methods temporarily own the DOM. Preserve every top-level
  // block covered by their selection; a cancellation may span several blocks.
  root.addEventListener('compositionstart', e => {
    const range = protectedRange(e)?.range || returningCaret() || selection() || remembered || [0, 0];
    const saved = blocks.slice(blockIndexAt(range[0]), blockIndexAt(range[1]) + 1)
      .map(block => [block, block.cloneNode(true)]);
    // Keep both the selection to display after reconciliation and the exact
    // revision that owns the composition. Only Swift can verify a replacement
    // across intervening edits without discarding somebody else's text.
    composing = {original: {range, version}, range, saved, deferred: []};
  });

  root.addEventListener('compositionend', e => {
    const session = composing;
    composing = null;
    if (!session) return;
    // Restore the authoritative DOM even on commit. Swift can refuse a commit.
    if (root.childNodes.length !== blocks.length || blocks.some((block, i) => root.childNodes[i] !== block)) {
      root.replaceChildren(...blocks);
    }
    for (const [block, saved] of session.saved) morph(block, saved);
    let range = session.range;
    for (const m of session.deferred) {
      marklight.patch(m);
      range = carryComposition(range, m.edits);
    }
    select(...range);
    if (e.data) {
      const committed = input('insertText', e.data, null, session.original.range);
      committed.fixed = session.original;
      enqueue(committed);
    }
  });

  const compositionInputs = new Set(['insertCompositionText', 'deleteCompositionText', 'insertFromComposition', 'deleteByComposition']);
  root.addEventListener('beforeinput', e => {
    if (composing && (e.isComposing || compositionInputs.has(e.inputType))) return;
    e.preventDefault();
    if (e.inputType === 'historyUndo' || e.inputType === 'historyRedo') {
      return enqueue({type: 'undo', redo: e.inputType === 'historyRedo'});
    }
    const r = e.getTargetRanges()[0];
    const target = r && root.contains(r.startContainer) && root.contains(r.endContainer)
      ? [toSource(r.startContainer, r.startOffset), toSource(r.endContainer, r.endOffset)] : null;
    // An ordinary key arriving before the previous edit/navigation lands has
    // no target in the resulting DOM yet. Use its caret at dispatch time.
    const stale = e.inputType === 'insertText' && (inFlight || pending.length || returningCaret());
    submit(e, input(e.inputType, e.data, stale ? null : target));
  });

  for (const [name, type] of [['paste', 'insertFromPaste'], ['drop', 'insertFromDrop']]) {
    root.addEventListener(name, e => {
      e.preventDefault();
      submit(e, input(type));
    });
  }
  root.addEventListener('dragover', e => e.preventDefault());

  const navigation = new Set(['ArrowLeft', 'ArrowRight', 'ArrowUp', 'ArrowDown', 'Home', 'End', 'PageUp', 'PageDown']);
  function replayMove({move, shift, alt, meta}) {
    const s = getSelection(), change = shift ? 'extend' : 'move';
    const forward = ['ArrowRight', 'ArrowDown', 'End', 'PageDown'].includes(move);
    const direction = forward ? 'forward' : 'backward';
    if (move === 'PageDown' || move === 'PageUp') {
      const top = () => {
        const caret = document.createRange();
        caret.setStart(s.focusNode, s.focusOffset);
        caret.collapse(true);
        return window.scrollY + caret.getBoundingClientRect().top;
      };
      const first = top();
      for (let lines = 0; lines < innerHeight && Math.abs(top() - first) < innerHeight; lines++) {
        const old = s.focusNode, at = s.focusOffset;
        s.modify(change, direction, 'line');
        if (s.focusNode === old && s.focusOffset === at) break;
      }
    } else {
      const vertical = move === 'ArrowUp' || move === 'ArrowDown';
      const unit = move === 'Home' || move === 'End' || (meta && vertical) ? 'documentboundary'
        : meta ? 'lineboundary' : vertical ? 'line' : alt ? 'word' : 'character';
      s.modify(change, direction, unit);
    }
    remembered = selection() || remembered;
    report();
  }

  root.addEventListener('keydown', e => {
    if (composing || e.isComposing || e.keyCode === 229) return;
    const returning = returningCaret();
    if (e.target === root && returning) select(...returning);
    if (navigation.has(e.key)) {
      if (inFlight || pending.length) {
        e.preventDefault();
        enqueue({move: e.key, shift: e.shiftKey, alt: e.altKey, meta: e.metaKey});
      } else {
        movedSinceInput = true;
      }
      return;
    }
    if (e.metaKey && e.key.toLowerCase() === 'z') {
      e.preventDefault();
      enqueue({type: 'undo', redo: e.shiftKey});
      return;
    }
    const format = e.metaKey && {b: 'formatBold', i: 'formatItalic', e: 'formatCode'}[e.key.toLowerCase()];
    const plain = !e.metaKey && !e.ctrlKey && !e.altKey;
    if (format || (plain && (e.key === 'Backspace' || e.key === 'Enter'))) {
      e.preventDefault();
      submit(e, input(format || (e.key === 'Backspace' ? 'deleteContentBackward' : e.shiftKey ? 'insertLineBreak' : 'insertParagraph')));
    } else if (plain && (e.key === 'Delete' || [...e.key].length === 1) && protectedRange(e)) {
      e.preventDefault();
      submit(e, e.key === 'Delete' ? input('deleteContentForward') : input('insertText', e.key));
    }
  });

  function carry(range, edits = []) {
    return range.map(offset => edits.reduce((at, [lo, hi, length]) =>
      at >= hi ? at + length - (hi - lo) : at > lo ? lo + length : at, offset));
  }

  function carryComposition(range, edits = []) {
    return edits.reduce((selection, edit) => {
      const [lo, hi] = edit;
      // Insertion exactly after the original selection stays outside it.
      if (lo === hi && selection[0] < lo && selection[1] === lo) return selection;
      return carry(selection, [edit]);
    }, range);
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
    if (!inFlight && !pending.length && navigation.has(e.key)) report();
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

  // WebKit treats a link inside an editing host as text, even for a Cmd-click.
  // Give just this gesture a native link so WKNavigationDelegate receives the
  // real linkActivated action with its original modifier flags and URL.
  let followingLink = null, restoreLinkTimer;
  function finishLinkGesture() {
    clearTimeout(restoreLinkTimer);
    if (followingLink) followingLink.removeAttribute('contenteditable');
    followingLink = null;
  }
  root.addEventListener('pointerdown', e => {
    finishLinkGesture();
    const link = e.target.closest?.('a[href]');
    if (e.isTrusted && e.metaKey && e.button === 0 && link?.isContentEditable) {
      followingLink = link;
      link.contentEditable = 'false';
    }
  }, true);
  // Pointerup may run in an earlier task than click. Restore editability
  // after the trusted click's default action has consulted the anchor.
  document.addEventListener('click', () => {
    if (followingLink) restoreLinkTimer = setTimeout(finishLinkGesture, 0);
  }, true);
  document.addEventListener('pointercancel', finishLinkGesture, true);
  document.addEventListener('dragend', finishLinkGesture, true);
  root.addEventListener('keydown', finishLinkGesture, true);

  document.addEventListener('click', e => {
    const link = e.target.closest && e.target.closest('a[href], area[href]');
    if (!link) return;
    if (!e.metaKey) { e.preventDefault(); return; }
    const name = fragment(link);
    if (!name) return;
    e.preventDefault();
    const target = anchorTarget(name);
    if (target) target.scrollIntoView();
  });

  globalThis.marklight = {
    /// Shows a whole document. `list` is `[{html, base}]`.
    load(list, v, start, end) {
      // A lost patch history invalidates every offset held by this page. A
      // late ACK only releases the old request; it cannot send an old intent.
      pending.length = 0;
      if (composing) {
        composing = null;
        root.blur();
      }
      remembered = null;
      movedSinceInput = true;
      const holder = document.createDocumentFragment();
      const made = list.map(b => holder.appendChild(makeBlock(b.html, b.base)));
      root.replaceChildren(holder);
      blocks = made;
      version = v;
      if (start != null && end != null) select(start, end);
    },

    select, selection,
    done() {
      inFlight = false;
      sendNext();
    },

    /// Replaces `remove` blocks at `from` with `list`, keeping every node it can.
    patch(m) {
      const live = blocks.slice(m.from, m.from + m.remove);
      if (composing) {
        if (composing.deferred.length || composing.saved.some(([block]) => live.includes(block) || !block.isConnected)) {
          composing.deferred.push(m);
          return;
        }
        composing.range = carryComposition(composing.range, m.edits);
      }
      const anchors = m.local ? [] : scrollAnchors();
      const s = getSelection();
      const selected = !composing && document.activeElement === root ? selection() : null;
      const touched = selected && (live.includes(blockOf(s.anchorNode)) || live.includes(blockOf(s.focusNode)));
      if (remembered) remembered = carry(remembered, m.edits);
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
      if (!composing) {
        if (m.local && m.caret && !movedSinceInput && document.activeElement === root) select(...m.caret);
        else if (touched) select(...carry(selected, m.edits));
      }
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
