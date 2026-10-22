import { mountChrome } from './chrome.js';

mountChrome();

// Where the register reads from. Until the contract is deployed this page says so
// plainly rather than rendering an empty table that looks like "nobody is bonded".
// The live API. VITE_THINKR_API overrides it for a local or staging API.
const API = import.meta.env.VITE_THINKR_API ?? 'https://api.thinkr.tech';

const rows = document.getElementById('rows');
const empty = document.getElementById('empty');
const src = document.getElementById('src');
const q = document.getElementById('q');

const money = (units) => `$${(Number(units) / 1e6).toLocaleString('en-US', { minimumFractionDigits: 2 })}`;

function render(list) {
  rows.innerHTML = list
    .map(
      (b) => `
      <div class="row" data-status="${b.status}">
        <span class="row__id mono">${b.agentId}</span>
        <span class="row__n mono">${money(b.bonded)}</span>
        <span class="row__n mono">${money(b.available)}</span>
        <span class="row__c mono">${b.claims.filed}&#8201;/&#8201;${b.claims.discharged}&#8201;/&#8201;${b.claims.paid}</span>
        <span class="row__s">${b.status.replace('_', ' ')}</span>
      </div>`
    )
    .join('');
  empty.hidden = list.length > 0;
}

async function lookup(id) {
  const [bond, claims] = await Promise.all([
    fetch(`${API}/v1/bond/${id}`).then((r) => r.json()),
    fetch(`${API}/v1/claims/${id}`).then((r) => r.json()),
  ]);
  if (bond.error) throw new Error(bond.error);
  return { ...bond, claims: claims.summary ?? { filed: 0, discharged: 0, paid: 0 } };
}

let everyone = [];

async function boot() {
  try {
    const [index, register] = await Promise.all([
      fetch(`${API}/`).then((r) => r.json()),
      fetch(`${API}/v1/bonds`).then((r) => r.json()),
    ]);
    const c = index.contracts.bonds;
    src.innerHTML = `Source: <a class="mono" href="${index.chain.explorer}/address/${c}" target="_blank" rel="noopener">${c.slice(0, 6)}…${c.slice(-4)}</a>`;
    everyone = register.bonds ?? [];
    render(everyone);
  } catch {
    src.innerHTML = 'Source: <span class="mono">unreachable</span>';
  }
}

q?.addEventListener('input', async () => {
  const id = q.value.trim();
  if (!id) {
    empty.textContent = 'No agent is bonded yet. The first one will appear here.';
    return render(everyone);
  }
  if (!/^\d+$/.test(id)) return;
  try {
    const b = await lookup(id);
    // typing 228 asks about 2, 22 and 228; only the answer for what is in the box counts
    if (q.value.trim() !== id) return;
    if (b.bonded === '0') {
      rows.innerHTML = '';
      empty.hidden = false;
      empty.textContent = `Agent ${id} has no bond.`;
      return;
    }
    render([b]);
  } catch (err) {
    if (q.value.trim() !== id) return;
    rows.innerHTML = '';
    empty.hidden = false;
    empty.textContent = err.message;
  }
});

boot();
