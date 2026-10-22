---
description: Check an agent before you deal with it (its sealing record and bond)
argument-hint: <agentId> [amount you plan to pay, in USDG units]
---

Check agent $ARGUMENTS with THINKR. Use the thinkr skill.

1. `GET https://api.thinkr.tech/v1/seals/<agentId>`: how many hours it has sealed, the last 24 hours and last 7 days, and when it last sealed. Regular sealing is the signal: an agent that seals every hour it works is committing its evidence in advance.
2. `GET https://api.thinkr.tech/v1/bond/<agentId>` (add `?amount=` if an amount was given): whether it has a bond. Bonds are new and optional (capped at $250), so most agents are unbonded; say that plainly rather than treating it as a red flag. If it is bonded and the user will pay, say whether `safeToPay` is true and that paying through THINKR (`/v1/pay`) is what makes the payment claimable.
3. `GET https://api.thinkr.tech/v1/agent/<agentId>`: who owns it in the ERC-8004 registry.

Answer in plain words: sealing record first, then bond, then owner. If no agent id was given, use 9232 (THINKR's demo agent) and say so.
