import { gsap } from 'gsap';
import { ScrollTrigger } from 'gsap/ScrollTrigger';
import { countTo } from './text.js';
import { lockOn, settle } from './reveal.js';

gsap.registerPlugin(ScrollTrigger);

/* width and height, never orientation */
export const BP = {
  pinned: '(min-width: 900px) and (min-height: 560px) and (prefers-reduced-motion: no-preference)',
  stacked: '(max-width: 899px), (max-height: 559px), (prefers-reduced-motion: reduce)',
  reduce: '(prefers-reduced-motion: reduce)',
};

export function initMotion() {
  gsap.matchMedia().add(BP, (ctx) => {
    const { reduce } = ctx.conditions;

    /* headings and statements both lock on, word by word */
    document.querySelectorAll('[data-lock]').forEach((el) => {
      if (reduce) return settle(el);
      ScrollTrigger.create({
        trigger: el,
        start: 'top 86%',
        once: true,
        onEnter: () => lockOn(el),
      });
    });

    /* the number counts */
    document.querySelectorAll('[data-count]').forEach((el) => {
      const v = Number(el.dataset.count);
      if (reduce) return (el.textContent = v.toLocaleString('en-GB'));
      el.textContent = '0';
      ScrollTrigger.create({
        trigger: el,
        start: 'top 92%',
        once: true,
        onEnter: () => countTo(el, v),
      });
    });

    if (reduce) {
      gsap.set('.rise', { autoAlpha: 1, y: 0 });
      gsap.set('.frame', { '--bracket': '16px' });
      return;
    }

    gsap.utils.toArray('.rise').forEach((el) =>
      gsap.to(el, {
        autoAlpha: 1,
        y: 0,
        duration: 0.8,
        ease: 'expo.out',
        scrollTrigger: { trigger: el, start: 'top 88%', once: true },
      })
    );

    /* bracket frames open with their panel */
    gsap.utils.toArray('.frame').forEach((f) =>
      gsap.fromTo(
        f,
        { '--bracket': '0px' },
        {
          '--bracket': '16px',
          duration: 0.5,
          ease: 'expo.out',
          scrollTrigger: { trigger: f.parentElement, start: 'top 88%', once: true },
        }
      )
    );
  });
}
