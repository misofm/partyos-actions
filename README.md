# Party Actions

Composable, custody-agnostic operations for Miso Party objects.

The Party ecosystem separates three kinds of package:

- **Extension** — a persistent, namespaced data slice attached to a `Party`.
- **Action** — public business logic that accepts the raw capability and returns
  caller-controlled assets for composition in the same PTB.
- **Plugin** — installed, permissionless automation backed by a capability Vault.

This repository contains actions. Actions do not define plugin witnesses,
installation records, recipient policy, or Vault custody. A caller may hold a
`PartyAdminCap` directly or borrow it from any compatible custody system, call an
action, and return the cap before the transaction ends.

## Packages

| Package | Purpose |
|---|---|
| [`party_wallet`](party_wallet) | Receive Party-addressed `key + store` objects and coins, or redeem Party accumulator funds, returning every asset to the caller. |

There is intentionally no Party wallet plugin. Every useful wallet operation
returns an object or `Balance` controlled by the caller, so permissionless
automation would create an extraction path rather than a safe crank.

Never send the sole matching `PartyAdminCap` to its own Party inbox: receiving
from that inbox requires the same cap, creating a circular authorization lock.
Likewise, `party_wallet` can receive only `key + store` objects; unsupported
non-`store` objects sent to the Party address are unrecoverable through this API.

## Build and test

Each package is independent:

```sh
cd party_wallet
sui move build
sui move test
sui move test --coverage
```

Git dependencies are pinned to full commit SHAs.

Coin-receipt events retain the consumed coin count, amounts and business identities.
They do not duplicate a variable-length list of input coin IDs; transaction inputs/effects provide that provenance when needed.
