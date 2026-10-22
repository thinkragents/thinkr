import { mountChrome } from './chrome.js';

mountChrome();

// Mark the section you are reading in the contents list. No library, no scroll
// handler running on every frame.
const seen = new Map();
const links = [...document.querySelectorAll('.toc a')];
const io = new IntersectionObserver(
  (entries) => {
    for (const e of entries) seen.set(e.target.id, e.intersectionRatio);
    let best = '', top = 0;
    for (const [id, r] of seen) if (r > top) { top = r; best = id; }
    links.forEach((a) => a.toggleAttribute('data-on', a.getAttribute('href') === `#${best}`));
  },
  { threshold: [0, 0.25, 0.5, 1], rootMargin: '-20% 0px -60% 0px' }
);
document.querySelectorAll('.doc__s').forEach((s) => io.observe(s));
