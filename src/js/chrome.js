// One definition of the nav, used by every page. Two copies is how they drift,
// and a nav that says something different on the register page than on the
// homepage reads as two different sites.

const NAV = [
  { label: 'Skill',     href: '/#skill'     },
  { label: 'Problem',   href: '/#problem'   },
  { label: 'Bond',      href: '/#bond'      },
  { label: 'Seal',      href: '/#proof'     },
  { label: 'Use',       href: '/#use'       },
  { label: 'Register',  href: '/bonds/'      },
  { label: 'Protocol',  href: '/docs/'       },
  { label: 'Integrate', href: '/#integrate' },
];

export const REPO = 'https://github.com/thinkragents/thinkr';

/** The GitHub mark, inline so it takes the link's colour. */
const GITHUB_MARK = `<svg viewBox="0 0 24 24" width="16" height="16" aria-hidden="true" fill="currentColor"><path d="M12 .297c-6.63 0-12 5.373-12 12 0 5.303 3.438 9.8 8.205 11.385.6.113.82-.258.82-.577 0-.285-.01-1.04-.015-2.04-3.338.724-4.042-1.61-4.042-1.61C4.422 18.07 3.633 17.7 3.633 17.7c-1.087-.744.084-.729.084-.729 1.205.084 1.838 1.236 1.838 1.236 1.07 1.835 2.809 1.305 3.495.998.108-.776.417-1.305.76-1.605-2.665-.3-5.466-1.332-5.466-5.93 0-1.31.465-2.38 1.235-3.22-.135-.303-.54-1.523.105-3.176 0 0 1.005-.322 3.3 1.23.96-.267 1.98-.399 3-.405 1.02.006 2.04.138 3 .405 2.28-1.552 3.285-1.23 3.285-1.23.645 1.653.24 2.873.12 3.176.765.84 1.23 1.91 1.23 3.22 0 4.61-2.805 5.625-5.475 5.92.42.36.81 1.096.81 2.22 0 1.606-.015 2.896-.015 3.286 0 .315.21.69.825.57C20.565 22.092 24 17.592 24 12.297c0-6.627-5.373-12-12-12"/></svg>`;

const here = () => location.pathname.replace(/\/$/, '') || '/';

/** True when a nav item points at the page we are already on. */
function current(href) {
  const path = href.split('#')[0].replace(/\/$/, '') || '/';
  return path === here();
}

export function mountNav(root = document.getElementById('nav')) {
  if (!root) return;
  const links = NAV.map((n) => {
    const on = current(n.href) && n.href.includes('#') === false;
    return `<a href="${n.href}"${on ? ' aria-current="page"' : ''}>${n.label}</a>`;
  }).join('');

  root.innerHTML = `
    <a class="mark" href="/" aria-label="THINKR">
      <img src="/logo.png" alt="THINKR" width="1812" height="261" />
    </a>
    <nav class="nav__links">${links}</nav>
    <a class="nav__gh" href="${REPO}" target="_blank" rel="noopener" aria-label="THINKR on GitHub">${GITHUB_MARK}<span>GitHub</span></a>
    <a class="act" href="/bonds/">Seal your agent</a>`;

  const stick = () => (root.dataset.stuck = window.scrollY > 24 ? '1' : '0');
  stick();
  window.addEventListener('scroll', stick, { passive: true });
}

export function mountChrome() {
  mountNav();
}
