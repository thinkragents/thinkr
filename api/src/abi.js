// Hand-written rather than generated, so the shape the API depends on is readable
// in one screen and a contract change that breaks it is visible in the diff.

export const bondsAbi = [
  {
    type: 'function',
    name: 'bonds',
    stateMutability: 'view',
    inputs: [{ name: 'agentId', type: 'uint256' }],
    outputs: [
      { name: 'amount', type: 'uint128' },
      { name: 'reserved', type: 'uint128' },
      { name: 'bondedAt', type: 'uint64' },
      { name: 'withdrawAfter', type: 'uint64' },
    ],
  },
  {
    type: 'function',
    name: 'available',
    stateMutability: 'view',
    inputs: [{ name: 'agentId', type: 'uint256' }],
    outputs: [{ type: 'uint128' }],
  },
  {
    type: 'function',
    name: 'claims',
    stateMutability: 'view',
    inputs: [{ name: 'claimId', type: 'uint256' }],
    outputs: [
      { name: 'agentId', type: 'uint256' },
      { name: 'claimant', type: 'address' },
      { name: 'amount', type: 'uint128' },
      { name: 'claimBond', type: 'uint128' },
      { name: 'epoch', type: 'uint64' },
      { name: 'filedAt', type: 'uint64' },
      { name: 'state', type: 'uint8' },
    ],
  },
  {
    type: 'function',
    name: 'roots',
    stateMutability: 'view',
    inputs: [
      { name: 'agentId', type: 'uint256' },
      { name: 'epoch', type: 'uint64' },
    ],
    outputs: [{ type: 'bytes32' }],
  },
  {
    type: 'function',
    name: 'claimBondFor',
    stateMutability: 'view',
    inputs: [{ name: 'amount', type: 'uint128' }],
    outputs: [{ type: 'uint128' }],
  },
  {
    type: 'function',
    name: 'currentEpoch',
    stateMutability: 'view',
    inputs: [],
    outputs: [{ type: 'uint64' }],
  },
  {
    type: 'function',
    name: 'attestDeadline',
    stateMutability: 'pure',
    inputs: [{ name: 'epoch', type: 'uint64' }],
    outputs: [{ type: 'uint256' }],
  },
  { type: 'function', name: 'minBond', stateMutability: 'view', inputs: [], outputs: [{ type: 'uint128' }] },
  {
    type: 'function',
    name: 'minClaimFor',
    stateMutability: 'view',
    inputs: [{ name: 'agentId', type: 'uint256' }],
    outputs: [{ type: 'uint128' }],
  },
  { type: 'function', name: 'EPOCH_LENGTH', stateMutability: 'view', inputs: [], outputs: [{ type: 'uint64' }] },
  { type: 'function', name: 'CHALLENGE_WINDOW', stateMutability: 'view', inputs: [], outputs: [{ type: 'uint64' }] },
  { type: 'function', name: 'CLAIM_PERIOD', stateMutability: 'view', inputs: [], outputs: [{ type: 'uint64' }] },
  { type: 'function', name: 'NOTICE_PERIOD', stateMutability: 'view', inputs: [], outputs: [{ type: 'uint64' }] },

  {
    type: 'function',
    name: 'bond',
    stateMutability: 'nonpayable',
    inputs: [
      { name: 'agentId', type: 'uint256' },
      { name: 'amount', type: 'uint128' },
    ],
    outputs: [],
  },
  {
    type: 'function',
    name: 'attest',
    stateMutability: 'nonpayable',
    inputs: [
      { name: 'agentId', type: 'uint256' },
      { name: 'epoch', type: 'uint64' },
      { name: 'root', type: 'bytes32' },
    ],
    outputs: [],
  },
  {
    type: 'function',
    name: 'fileClaim',
    stateMutability: 'nonpayable',
    inputs: [
      { name: 'agentId', type: 'uint256' },
      { name: 'ref', type: 'bytes32' },
      { name: 'epoch', type: 'uint64' },
      { name: 'amount', type: 'uint128' },
    ],
    outputs: [{ type: 'uint256' }],
  },
  {
    type: 'function',
    name: 'discharge',
    stateMutability: 'nonpayable',
    inputs: [
      { name: 'claimId', type: 'uint256' },
      { name: 'ref', type: 'bytes32' },
      { name: 'digest', type: 'bytes32' },
      { name: 'proof', type: 'bytes32[]' },
    ],
    outputs: [],
  },
  {
    type: 'function',
    name: 'settle',
    stateMutability: 'nonpayable',
    inputs: [{ name: 'claimId', type: 'uint256' }],
    outputs: [],
  },

  {
    type: 'event',
    name: 'Attested',
    inputs: [
      { name: 'agentId', type: 'uint256', indexed: true },
      { name: 'epoch', type: 'uint64', indexed: true },
      { name: 'root', type: 'bytes32', indexed: false },
    ],
  },
  {
    type: 'event',
    name: 'Bonded',
    inputs: [
      { name: 'agentId', type: 'uint256', indexed: true },
      { name: 'from', type: 'address', indexed: true },
      { name: 'amount', type: 'uint128', indexed: false },
      { name: 'total', type: 'uint128', indexed: false },
    ],
  },
  {
    type: 'event',
    name: 'ClaimFiled',
    inputs: [
      { name: 'claimId', type: 'uint256', indexed: true },
      { name: 'agentId', type: 'uint256', indexed: true },
      { name: 'claimant', type: 'address', indexed: true },
      { name: 'ref', type: 'bytes32' },
      { name: 'epoch', type: 'uint64' },
      { name: 'amount', type: 'uint128' },
      { name: 'claimBond', type: 'uint128' },
    ],
  },
  {
    type: 'event',
    name: 'ClaimDischarged',
    inputs: [
      { name: 'claimId', type: 'uint256', indexed: true },
      { name: 'agentId', type: 'uint256', indexed: true },
      { name: 'digest', type: 'bytes32' },
    ],
  },
  {
    type: 'event',
    name: 'ClaimSettled',
    inputs: [
      { name: 'claimId', type: 'uint256', indexed: true },
      { name: 'agentId', type: 'uint256', indexed: true },
      { name: 'paid', type: 'uint128' },
    ],
  },
];

export const registryAbi = [
  {
    type: 'function',
    name: 'register',
    stateMutability: 'nonpayable',
    inputs: [{ name: 'agentURI', type: 'string' }],
    outputs: [{ name: 'agentId', type: 'uint256' }],
  },
  {
    type: 'function',
    name: 'ownerOf',
    stateMutability: 'view',
    inputs: [{ name: 'agentId', type: 'uint256' }],
    outputs: [{ type: 'address' }],
  },
];

export const erc20Abi = [
  { type: 'function', name: 'decimals', stateMutability: 'view', inputs: [], outputs: [{ type: 'uint8' }] },
  { type: 'function', name: 'symbol', stateMutability: 'view', inputs: [], outputs: [{ type: 'string' }] },
  {
    type: 'function',
    name: 'approve',
    stateMutability: 'nonpayable',
    inputs: [
      { name: 'spender', type: 'address' },
      { name: 'amount', type: 'uint256' },
    ],
    outputs: [{ type: 'bool' }],
  },
];
