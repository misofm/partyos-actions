# party_wallet

Custody-agnostic wallet actions for a Party's two native inboxes. `key + store`
objects sent to the Party object address are received by ticket; funds sent to its balance
accumulator are redeemed by amount. Every operation is authorized by the exact
`PartyAdminCap` and returns the withdrawn asset to the caller for PTB composition.

The package stores no data and has no plugin installation surface. A cap may be
owned directly, held in a Vault, or supplied by another custody system without
changing this API.

> [!WARNING]
> Never send the sole matching `PartyAdminCap` to its own Party inbox. Receiving
> it requires that same cap, creating a circular authorization lock. Objects
> without `store` are unsupported and, if sent to the Party address, cannot be
> recovered through `party_wallet`.

## API

| Function | Returns | Aborts |
|---|---|---|
| `receive<T: key + store>(party, admin_cap, ticket)` | The exact received `T` | Wrong Party cap; invalid receiving ticket |
| `receive_balance<Currency>(party, admin_cap, coins)` | All received coins merged as `Balance<Currency>` | Wrong Party cap; empty input (`0`); invalid ticket |
| `redeem_balance<Currency>(party, admin_cap, value)` | Redeemed `Balance<Currency>` | Wrong Party cap; zero value (`party_wallet` code `1`); accumulator failure |
| `inbox_address(party)` | Party object ID as an address | Never |

There are deliberately no coin-return wrappers, batch object helpers, recipient
parameters, internal transfers, `entry` wrappers, settled-funds view, Vault
types, witnesses, or install functions.

## Events

| Event | Payload |
|---|---|
| `ObjectReceivedEvent<T>` | `party_id`, `object_id` |
| `CoinsReceivedEvent<Currency>` | `party_id`, merged `amount`, input `coins` count |
| `FundsRedeemedEvent<Currency>` | `party_id`, redeemed `amount` |

`FundsRedeemedEvent<Currency>` is the Party-domain Move receipt. The same
redemption also produces the framework accumulator's typed `Split` effect;
consumers that ingest both surfaces must not count them as two redemptions.

## Accumulator testing boundary

The Move VM executes direct accumulator credit and redemption paths, including
partial redemption, overdraw, zero-value rejection, and event payloads. Its
`AccumulatorRoot` test snapshot remains commit-settled and does not expose a
positive funded value, so the suite also documents and tests the reachable zero
snapshot path without inventing an on-chain result.

## Build and test

```sh
sui move build
sui move test
sui move test --coverage
```
