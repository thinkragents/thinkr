import { gsap } from 'gsap';

const POOL = '01▁▂▃▄▅▆▇█/\\<>+=*#$%&@'.split('');
const pick = () => POOL[(Math.random() * POOL.length) | 0];

/* resolves left to right with a ragged edge */
export function scramble(el, { duration = 0.9 } = {}) {
  const text = (el.dataset.text ??= el.textContent);
  const chars = [...text];
  const at = chars.map((c, i) =>
    c === ' ' ? 0 : (i / chars.length) * 0.6 + Math.random() * 0.4
  );
  const s = { p: 0 };
  el._scr?.kill();
  el._scr = gsap.to(s, {
    p: 1,
    duration,
    ease: 'none',
    onUpdate() {
      let out = '';
      for (let i = 0; i < chars.length; i++)
        out += s.p >= at[i] ? chars[i] : `<i class="scr">${pick()}</i>`;
      el.innerHTML = out;
    },
    onComplete() {
      el.textContent = text;
    },
  });
  return el._scr;
}

/* counts a number up, keeping the grouping */
export function countTo(el, value, { duration = 1.6 } = {}) {
  const s = { v: 0 };
  return gsap.to(s, {
    v: value,
    duration,
    ease: 'expo.out',
    onUpdate: () => (el.textContent = Math.round(s.v).toLocaleString('en-GB')),
  });
}

/* word wrappers so a line never breaks between letters */
export function splitChars(el) {
  if (el.dataset.split === '1') return [...el.querySelectorAll('.ltr')];
  const walk = (node) => {
    [...node.childNodes].forEach((n) => {
      if (n.nodeType === 3) {
        const frag = document.createDocumentFragment();
        n.textContent.split(/(\s+)/).forEach((part) => {
          if (!part) return;
          if (/^\s+$/.test(part)) return frag.appendChild(document.createTextNode(' '));
          const w = document.createElement('span');
          w.className = 'wrd';
          [...part].forEach((ch) => {
            const s = document.createElement('span');
            s.className = 'ltr';
            s.textContent = ch;
            w.appendChild(s);
          });
          frag.appendChild(w);
        });
        n.replaceWith(frag);
      } else if (n.nodeType === 1) walk(n);
    });
  };
  walk(el);
  el.dataset.split = '1';
  return [...el.querySelectorAll('.ltr')];
}
