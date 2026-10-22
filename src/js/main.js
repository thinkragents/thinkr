import Lenis from 'lenis';
import { gsap } from 'gsap';
import { ScrollTrigger } from 'gsap/ScrollTrigger';
import { initMotion } from './motion.js';
import { mountChrome } from './chrome.js';
import { initScene } from './scene.js';

gsap.registerPlugin(ScrollTrigger);
const reduced = document.documentElement.classList.contains('reduced');

/* nav comes from one definition, shared with /docs and /bonds */
mountChrome();

/* scroll */
if (!reduced) {
  const lenis = new Lenis({ lerp: 0.1, smoothWheel: true });
  lenis.on('scroll', ScrollTrigger.update);
  gsap.ticker.add((t) => lenis.raf(t * 1000));
  gsap.ticker.lagSmoothing(0);
  document.querySelectorAll('a[href^="#"]').forEach((a) =>
    a.addEventListener('click', (e) => {
      const t = document.querySelector(a.getAttribute('href'));
      if (!t) return;
      e.preventDefault();
      lenis.scrollTo(t, { offset: -70 });
    })
  );
}

initMotion();

/* WebGL is expensive and pointless if motion is off */
if (!reduced) initScene(document.getElementById('scene'));
window.addEventListener('load', () => ScrollTrigger.refresh());


/* The brand mark plays only while it is on screen. autoplay gets it
   going, this stops it burning frames once it has scrolled away. */
(function markVideo() {
  const v = document.querySelector('.stamp video');
  if (!v) return;
  v.play().catch(() => {});
  new IntersectionObserver(([e]) => {
    if (e.isIntersecting) v.play().catch(() => {});
    else v.pause();
  }, { threshold: 0.1 }).observe(v);
})();
