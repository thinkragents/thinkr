/* ===========================================================
   Text reveal. Deliberately not a character scramble.

   A heading arrives out of focus and slightly low, then locks
   on word by word, like a readout resolving. A thin rule sweeps
   across as it settles. Quieter and more mechanical than a
   jumble, which suits a thing whose whole claim is precision.
   =========================================================== */

import { gsap } from 'gsap';

export function splitWords(el) {
  if (el.dataset.words === '1') return [...el.querySelectorAll('.wd')];
  const walk = (node) => {
    [...node.childNodes].forEach((n) => {
      if (n.nodeType === 3) {
        const frag = document.createDocumentFragment();
        n.textContent.split(/(\s+)/).forEach((part) => {
          if (!part) return;
          if (/^\s+$/.test(part)) return frag.appendChild(document.createTextNode(' '));
          const w = document.createElement('span');
          w.className = 'wd';
          w.textContent = part;
          frag.appendChild(w);
        });
        n.replaceWith(frag);
      } else if (n.nodeType === 1) walk(n);
    });
  };
  walk(el);
  el.dataset.words = '1';
  return [...el.querySelectorAll('.wd')];
}

export function lockOn(el) {
  const words = splitWords(el);
  gsap.set(words, { filter: 'blur(14px)', opacity: 0, y: '0.18em' });
  const tl = gsap.timeline();
  tl.to(words, {
    filter: 'blur(0px)',
    opacity: 1,
    y: '0em',
    duration: 0.72,
    ease: 'expo.out',
    stagger: 0.075,
  });
  const sweep = el.querySelector('.sweep');
  if (sweep) {
    tl.fromTo(sweep, { scaleX: 0, transformOrigin: 'left' },
      { scaleX: 1, duration: 0.5, ease: 'power2.inOut' }, 0.1)
      .to(sweep, { scaleX: 0, transformOrigin: 'right', duration: 0.4, ease: 'power2.in' }, '>-0.05');
  }
  return tl;
}

export function settle(el) {
  gsap.set(splitWords(el), { filter: 'none', opacity: 1, y: 0 });
}
