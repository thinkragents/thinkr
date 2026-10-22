import { mountChrome } from './chrome.js';

mountChrome();

// Where the register reads from. Until the contract is deployed this page says so
// plainly rather than rendering an empty table that looks like "nobody is bonded".
// The live API. Becomes https://api.thinkr.tech once the domain points at Render;
// VITE_THINKR_API overrides it for a local or staging API.
const API = import.meta.env.VITE_THINKR_API ?? 'https://thinkr-api.onrender.com';

const rows = document.getElementById('rows');
const empty = document.getElementById('empty');
const src = document.getElementById('src');
const q = document.getElementById('q');

const money = (units) => `$${(Number(units) / 1e6).toLocaleString('en-US', { minimumFractionDigits: 2 })}`;

function render(list) {
  rows.innerHTML = list
    .map(
      (b) => `
      <a class="row" href="/docs/" data-status="${b.status}">
        <span class="row__id mono">${b.agentId}</span>
        <span class="row__n mono">${money(b.bonded)}</span>
        <span class="row__n mono">${money(b.available)}</span>
        <span class="row__c mono">${b.claims.filed}&#8201;/&#8201;${b.claims.discharged}&#8201;/&#8201;${b.claims.paid}</span>
        <span class="row__s">${b.status.replace('_', ' ')}</span>
      </a>`
    )
    .join('');
  empty.hidden = list.length > 0;
}

async function lookup(id) {
  if (!API) return null;
  const [bond, claims] = await Promise.all([
    fetch(`${API}/v1/bond/${id}`).then((r) => r.json()),
    fetch(`${API}/v1/claims/${id}`).then((r) => r.json()),
  ]);
  if (bond.error) throw new Error(bond.error);
  return { ...bond, claims: claims.summary ?? { filed: 0, discharged: 0, paid: 0 } };
}

async function boot() {
  if (!API) {
    src.innerHTML = 'Source: <span class="mono">contract not deployed</span>';
    q.disabled = true;
    return;
  }
  try {
    const index = await fetch(`${API}/`).then((r) => r.json());
    src.innerHTML = `Source: <a class="mono" href="${index.chain.explorer}/address/${index.contracts.bonds}">${index.contracts.bonds}</a>`;
  } catch {
    src.innerHTML = 'Source: <span class="mono">unreachable</span>';
  }
}

q?.addEventListener('change', async () => {
  const id = q.value.trim();
  if (!id) return render([]);
  try {
    const b = await lookup(id);
    render(b ? [b] : []);
  } catch (err) {
    empty.hidden = false;
    empty.textContent = err.message;
    rows.innerHTML = '';
  }
});

boot();
