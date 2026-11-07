// ==UserScript==
// @name         Gmail Content Hider
// @namespace    toolshed.local
// @version      2.1.0
// @description  Hides named attachments, phrases and elements in Gmail, and re-applies the rules after every refresh.
// @match        https://mail.google.com/*
// @match      https://mail.google.com/mail/*
// @grant        GM_getValue
// @grant        GM_setValue
// @grant        GM_registerMenuCommand
// @run-at       document-start
// ==/UserScript==

/*
  Rule syntax, one per line, from the Tampermonkey menu -> "Manage hidden content".

    att: LENTERIA LEDGER.pdf        hide the attachment card
    hide: Please see attached       remove the whole block holding the phrase
    redact: 4419-0021               paint a bar over the words, keep the layout
    css: div.aQH                    hide everything matching a selector

  # starts a comment.

  hide: removes the enclosing block, so it takes the entire paragraph even when
  the rule matches only part of it. For part of a sentence use redact: instead.
*/

(() => {
  'use strict';

  const KEY = 'gmailHiderRules';
  const ATTR = 'data-hider-off';
  const TOP = window.top === window.self;

  const DEFAULTS = [
    'att: LENTERIA LEDGER.pdf',
    'hide: Please see attached ledger sir',
  ].join('\n');

  const CSS_TEXT =
    `[${ATTR}] { display: none !important; }`
    + `.gh-bar { background:#202124; color:transparent; border-radius:2px;`
    + ` user-select:none; -webkit-user-select:none; }`;

  // Gmail sanitises received HTML but keeps <font>, <span class="gmail_default">
  // and inline styles exactly as sent, and gives nothing a stable id. So rules
  // are written as plain phrases and resolved to whatever element carries them.

  // ------------------------------------------------------------------ rules

  function source() {
    return GM_getValue(KEY, DEFAULTS);
  }

  function rules() {
    const out = { att: [], hide: [], redact: [], css: [] };
    for (const line of source().split('\n')) {
      const t = line.trim();
      if (!t || t.startsWith('#')) continue;
      const i = t.indexOf(':');
      if (i < 1) continue;
      const kind = t.slice(0, i).trim().toLowerCase();
      const value = t.slice(i + 1).trim();
      if (value && out[kind]) out[kind].push(value);
    }
    return out;
  }

  const escapeRe = (s) => s.replace(/[.*+?^${}()|[\]\\]/g, '\\$&');

  // Whitespace in Gmail's HTML is unpredictable (&nbsp;, line breaks, run
  // splits), so a phrase is compiled to "word \s+ word" rather than compared
  // literally.
  function looseRe(phrase, flags) {
    return new RegExp(phrase.trim().split(/\s+/).map(escapeRe).join('\\s+'), flags || 'i');
  }

  // ----------------------------------------------------------- frame walk

  // The message body is a srcdoc iframe: same-origin, but a document of its
  // own, and its rules can only be applied from here. Traversing from the top
  // document also avoids depending on whether the manager injected per frame.
  function documents() {
    const docs = [];
    const seen = new Set();
    const collect = (doc) => {
      if (!doc || seen.has(doc)) return;
      seen.add(doc);
      docs.push(doc);
      for (const frame of doc.querySelectorAll('iframe')) {
        let inner = null;
        try {
          inner = frame.contentDocument;
        } catch {
          inner = null;
        }
        collect(inner);
      }
    };
    collect(document);
    return docs;
  }

  function paintStyle(doc) {
    if (!doc.head || doc.querySelector('style[data-gh]')) return;
    const s = doc.createElement('style');
    s.setAttribute('data-gh', '');
    s.textContent = CSS_TEXT;
    doc.head.appendChild(s);
  }

  // --------------------------------------------------------- text rules

  function textNodes(doc) {
    if (!doc.body) return [];
    const out = [];
    const walker = doc.createTreeWalker(doc.body, NodeFilter.SHOW_TEXT);
    while (walker.nextNode()) {
      if (walker.currentNode.nodeValue && walker.currentNode.nodeValue.trim()) {
        out.push(walker.currentNode);
      }
    }
    return out;
  }

  // Climb only while the ancestor contributes no other text, and stop at the
  // message container. Without the stop, a one-line email would hide its own
  // bubble, and hiding the body wrapper would blank the whole message.
  function smallestBlock(doc, node) {
    let el = node.parentElement;
    if (!el) return null;
    for (let depth = 0; depth < 8 && el.parentElement; depth += 1) {
      const parent = el.parentElement;
      if (parent.matches('[role="article"], .adn, .a3s, .gmail_quote, body')) break;
      if (parent.textContent.replace(/\s+/g, ' ').trim()
          !== el.textContent.replace(/\s+/g, ' ').trim()) break;
      el = parent;
    }
    return el;
  }

  function runHide(doc, phrases) {
    const nodes = textNodes(doc);
    for (const phrase of phrases) {
      const re = looseRe(phrase);
      for (const node of nodes) {
        if (!re.test(node.nodeValue)) continue;
        const block = smallestBlock(doc, node);
        if (block) block.setAttribute(ATTR, '');
      }
    }
  }

  function runRedact(doc, phrases) {
    const nodes = textNodes(doc);
    for (const phrase of phrases) {
      const re = looseRe(phrase, 'gi');
      const targets = nodes.filter((n) => {
        re.lastIndex = 0;
        return re.test(n.nodeValue);
      });
      for (const node of targets) {
        if (!node.parentNode) continue;
        const frag = doc.createDocumentFragment();
        let last = 0;
        let m;
        re.lastIndex = 0;
        while ((m = re.exec(node.nodeValue)) !== null) {
          frag.appendChild(doc.createTextNode(node.nodeValue.slice(last, m.index)));
          const bar = doc.createElement('span');
          bar.className = 'gh-bar';
          bar.dataset.raw = m[0];
          bar.textContent = '#'.repeat(Math.min(Math.max(m[0].length, 4), 28));
          frag.appendChild(bar);
          last = m.index + m[0].length;
          if (m[0].length === 0) re.lastIndex += 1;
        }
        frag.appendChild(doc.createTextNode(node.nodeValue.slice(last)));
        node.parentNode.replaceChild(frag, node);
      }
    }
  }

  function restoreBars(doc) {
    for (const bar of doc.querySelectorAll('.gh-bar')) {
      const parent = bar.parentNode;
      if (!parent) continue;
      parent.replaceChild(doc.createTextNode(bar.dataset.raw || ''), bar);
      parent.normalize();
    }
  }

  // ------------------------------------------------------- attachments

  // Gmail reassigns ids like ":1ad" on every render, so they are worthless as
  // anchors; the filename is the only thing that survives a refresh.
  const CARD = 'div.aQH';
  const SECTION = 'div.hq';

  function runAttachments(list) {
    const cards = new Set();
    const hits = document.querySelectorAll(
      'a[href*="view=att"], img[src*="view=snatt"], span.aV3, ' + CARD
    );
    for (const el of hits) {
      const card = el.closest(CARD);
      if (card) cards.add(card);
    }

    const hidden = new Set();
    if (list.length) {
      for (const card of cards) {
        const labels = [...card.querySelectorAll('[aria-label]')]
          .map((n) => n.getAttribute('aria-label')).join(' ');
        const hay = `${card.textContent} ${labels}`;
        if (list.some((name) => looseRe(name).test(hay))) hidden.add(card);
      }
    }
    for (const card of hidden) card.setAttribute(ATTR, '');

    // If nothing in the section survives, take the section: otherwise "One
    // attachment - Scanned by Gmail" and the "Added to Drive" chip remain and
    // announce that something was removed.
    for (const section of document.querySelectorAll(SECTION)) {
      const inner = [...section.querySelectorAll(CARD)];
      if (inner.length && inner.every((c) => hidden.has(c))) section.setAttribute(ATTR, '');
    }

    // The bulk download control would hand the file straight back.
    const bulk = byTextLoose(document, 'Download all attachments');
    for (const el of bulk) {
      const scope = el.closest('div[role="article"]') || el.parentElement;
      const inner = scope ? [...scope.querySelectorAll(CARD)] : [];
      if (inner.length && inner.every((c) => hidden.has(c))) el.setAttribute(ATTR, '');
    }
  }

  function byTextLoose(doc, phrase) {
    const out = [];
    const re = looseRe(phrase);
    try {
      const path = `//*[self::a or self::span][contains(normalize-space(.), `
        + `${JSON.stringify(phrase.split(/\s+/)[0])})]`;
      const it = doc.evaluate(path, doc, null, XPathResult.ORDERED_NODE_SNAPSHOT_TYPE, null);
      for (let i = 0; i < it.snapshotLength; i += 1) {
        const el = it.snapshotItem(i);
        if (re.test(el.textContent)) out.push(el);
      }
    } catch {
      /* XPath unavailable */
    }
    return out;
  }

  function runCss(doc, selectors) {
    for (const sel of selectors) {
      try {
        doc.querySelectorAll(sel).forEach((el) => el.setAttribute(ATTR, ''));
      } catch {
        /* ignore a selector this document rejects */
      }
    }
  }

  // ------------------------------------------------------------ driver

  function apply() {
    const r = rules();
    const docs = documents();

    // Clear, then repaint. All of this runs in one synchronous task so the
    // browser paints nothing in between: un-hiding is instant and flash-free.
    for (const doc of docs) {
      for (const el of doc.querySelectorAll(`[${ATTR}]`)) el.removeAttribute(ATTR);
      restoreBars(doc);
    }

    const empty = !r.att.length && !r.hide.length && !r.redact.length && !r.css.length;
    if (empty) return;

    for (const doc of docs) {
      paintStyle(doc);
      if (r.hide.length) runHide(doc, r.hide);
      if (r.redact.length) runRedact(doc, r.redact);
      if (r.css.length) runCss(doc, r.css);
    }
    if (TOP && r.att.length) runAttachments(r.att);
  }

  let queued = false;
  function schedule() {
    if (queued) return;
    queued = true;
    setTimeout(() => {
      queued = false;
      apply();
      // A message body iframe appears after the thread renders; watch it so its
      // own late mutations are picked up, but attach only once per document.
      for (const doc of documents()) {
        if (!doc.body || watchList.has(doc)) continue;
        watchList.add(doc);
        new MutationObserver(schedule).observe(doc.documentElement, {
          childList: true,
          subtree: true,
        });
      }
    }, 300);
  }

  const watchList = new WeakSet();

  // documentElement, because at document-start there is no body yet.
  new MutationObserver(schedule).observe(document.documentElement, {
    childList: true,
    subtree: true,
  });
  window.addEventListener('hashchange', schedule);

  // --------------------------------------------------------------- panel

  function openPanel() {
    if (document.getElementById('gh-panel')) return;
    const box = document.createElement('div');
    box.id = 'gh-panel';
    box.style.cssText = 'position:fixed;top:80px;right:24px;z-index:2147483647;'
      + 'width:440px;background:#fff;color:#202124;border:1px solid #dadce0;'
      + 'border-radius:8px;box-shadow:0 8px 24px rgba(0,0,0,.25);padding:14px;'
      + 'font:13px/1.5 Roboto,Arial,sans-serif';

    const title = document.createElement('b');
    title.textContent = 'Hidden content';
    const help = document.createElement('p');
    help.style.cssText = 'margin:6px 0 10px;color:#5f6368';
    help.textContent = 'One rule per line. Re-applied on every load, in this browser only.';
    const area = document.createElement('textarea');
    area.id = 'gh-rules';
    area.style.cssText = 'width:100%;height:200px;font:12px monospace';
    area.value = source();
    const syntax = document.createElement('pre');
    syntax.style.cssText = 'margin:10px 0 12px;color:#5f6368;white-space:pre-wrap';
    syntax.textContent = 'att: file.pdf\nhide: some phrase\nredact: 4419-0021\ncss: div.aQH';

    const save = document.createElement('button');
    save.textContent = 'Save';
    save.onclick = () => {
      GM_setValue(KEY, area.value);
      box.remove();
      apply();
    };
    const close = document.createElement('button');
    close.textContent = 'Close';
    close.onclick = () => box.remove();

    const row = document.createElement('div');
    save.style.marginRight = '8px';
    row.append(save, close);

    box.append(title, help, area, row, syntax);
    document.body.appendChild(box);
    area.focus();
  }

  if (TOP && typeof GM_registerMenuCommand === 'function') {
    GM_registerMenuCommand('Manage hidden content', openPanel);
  }

  apply();
})();
