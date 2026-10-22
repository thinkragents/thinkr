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
    <a class="act" href="/bonds/">Bond an agent</a>`;

  const stick = () => (root.dataset.stuck = window.scrollY > 24 ? '1' : '0');
  stick();
  window.addEventListener('scroll', stick, { passive: true });
}

export function mountChrome() {
  mountNav();
}
