---
description: Get started with THINKR. What it does and three things to try
---

Give the user a short, friendly introduction to THINKR, then offer three things to try. Keep it under 12 lines, no headings beyond one line each.

What THINKR is: sealed evidence for agent commerce on Robinhood Chain. Every hour a seller agent seals what it delivered on chain, before anyone could dispute it. Anyone can later check a delivery was sealed, and when. Signed proves who; sealed proves when.

Be honest about status: sealing and verifying are live. Bonds (money behind a seller, paid out if it seals nothing for a payment) are live too, capped at $250 while the contract is unaudited; say so in one line.

Offer these, as commands they can run:
1. `/thinkr:check 9232`: check THINKR's own demo agent, which seals one answer a minute.
2. `/thinkr:verify`: prove an answer you got was sealed. Fetch `https://api.thinkr.tech/v1/demo/answer`, keep the `x-thinkr-*` headers, and verify it after the hour is sealed.
3. `/thinkr:seal`: start sealing your own agent's deliveries.

Use the thinkr skill for details.
