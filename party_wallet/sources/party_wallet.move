// Copyright (c) Miso Labs, Inc.
// SPDX-License-Identifier: Apache-2.0

/// Custody-agnostic wallet actions for a Party.
///
/// A Party ID is both an object ID and an address. Anyone may send transferable
/// objects or accumulator funds to that stable address, while only the matching
/// `PartyAdminCap` can expose the Party UID needed to withdraw them. These raw-cap
/// actions return every withdrawn asset to the caller so direct owners, Vault
/// administrators, and other custody systems can compose the same immutable API.
///
/// This package stores no Party data and defines no plugin or transfer policy.
module party_wallet::party_wallet;

use hikida::hikida;
use partyos::party::{Party, PartyAdminCap};
use sui::balance::Balance;
use sui::coin::Coin;
use sui::event::emit;
use sui::transfer::Receiving;

// === Errors ===

/// No coin tickets were supplied to `receive_balance`.
const ENothingToReceive: u64 = 0;
/// Zero-value redemption is rejected by the Party wallet Action.
const ENoValueToRedeem: u64 = 1;

// === Events ===

/// Emitted when one object is received from a Party's object inbox.
public struct ObjectReceivedEvent<phantom T> has copy, drop {
    party_id: ID,
    object_id: ID,
}

/// Emitted when coin objects are received and merged into one balance.
public struct CoinsReceivedEvent<phantom Currency> has copy, drop {
    party_id: ID,
    amount: u64,
    coins: u64,
}

/// Emitted when funds are redeemed from a Party's accumulator.
public struct FundsRedeemedEvent<phantom Currency> has copy, drop {
    party_id: ID,
    amount: u64,
}

// === Actions ===

/// Receive and return one `key + store` object addressed to `party`.
///
/// Aborts if `admin_cap` belongs to another Party or the receiving ticket does
/// not identify an object addressed to this Party.
public fun receive<T: key + store>(
    party: &mut Party,
    admin_cap: &PartyAdminCap,
    object_to_receive: Receiving<T>,
): T {
    let party_id = object::id(party);
    let received = transfer::public_receive(party.uid_mut(admin_cap), object_to_receive);
    emit(ObjectReceivedEvent<T> { party_id, object_id: object::id(&received) });
    received
}

/// Receive a non-empty set of coin objects addressed to `party`, merge them,
/// and return their combined `Balance`.
///
/// Aborts with `ENothingToReceive` when `coins` is empty, if `admin_cap`
/// belongs to another Party, or if any ticket is invalid for this Party.
public fun receive_balance<Currency>(
    party: &mut Party,
    admin_cap: &PartyAdminCap,
    coins: vector<Receiving<Coin<Currency>>>,
): Balance<Currency> {
    assert!(!coins.is_empty(), ENothingToReceive);
    let party_id = object::id(party);
    let count = coins.length();
    let balance = hikida::receive_coins_as_balance(party.uid_mut(admin_cap), coins);
    emit(CoinsReceivedEvent<Currency> { party_id, amount: balance.value(), coins: count });
    balance
}

/// Redeem `value` from `party`'s accumulator and return the resulting balance.
///
/// Aborts if `admin_cap` belongs to another Party. Accumulator semantics remain
/// in `hikida`: this Action rejects zero with `ENoValueToRedeem`, and unavailable funds abort in
/// the Sui accumulator implementation.
public fun redeem_balance<Currency>(
    party: &mut Party,
    admin_cap: &PartyAdminCap,
    value: u64,
): Balance<Currency> {
    let party_id = object::id(party);
    let uid = party.uid_mut(admin_cap);
    assert!(value > 0, ENoValueToRedeem);
    let balance = hikida::redeem_balance<Currency>(uid, value);
    emit(FundsRedeemedEvent<Currency> { party_id, amount: balance.value() });
    balance
}

/// Return the Party ID as the address to which objects and funds may be sent.
public fun inbox_address(party: &Party): address {
    object::id(party).to_address()
}

// === Test helpers ===

#[test_only]
public fun object_received_event_fields<T>(event: &ObjectReceivedEvent<T>): (ID, ID) {
    (event.party_id, event.object_id)
}

#[test_only]
public fun coins_received_event_fields<Currency>(
    event: &CoinsReceivedEvent<Currency>,
): (ID, u64, u64) {
    (event.party_id, event.amount, event.coins)
}

#[test_only]
public fun funds_redeemed_event_fields<Currency>(
    event: &FundsRedeemedEvent<Currency>,
): (ID, u64) {
    (event.party_id, event.amount)
}
