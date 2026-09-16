// Copyright (c) Miso Labs, Inc.
// SPDX-License-Identifier: Apache-2.0

#[test_only]
module party_wallet::party_wallet_tests;

use partyos::party::{Self, Party, PartyAdminCap};
use party_wallet::party_wallet as action;
use std::unit_test::{assert_eq, destroy};
use sui::accumulator::AccumulatorRoot;
use sui::balance;
use sui::coin::{Self, Coin};
use sui::event;
use sui::sui::SUI;
use sui::test_scenario as ts;
use vault::vault::{Self, Vault, VaultAdminCap};

const ADMIN: address = @0xA;
const RECIPIENT: address = @0xB;
/// `accumulator::create_for_testing` is system-only.
const SYSTEM: address = @0x0;

/// Mirrors `partyos::party::EUnauthorized`.
const EUnauthorized: u64 = 0;
/// Mirrors `party_wallet::party_wallet::ENoValueToRedeem`.
const ENoValueToRedeem: u64 = 1;
/// Mirrors `vault::vault::ENotVaultAdmin`.
const ENotVaultAdmin: u64 = 0;

/// A non-coin `key + store` object, shaped like an asset or capability.
public struct StakeLike has key, store {
    id: UID,
    amount: u64,
}

// === Fixtures ===

fun new_party(group: bool, ctx: &mut TxContext): (Party, PartyAdminCap) {
    let clock = sui::clock::create_for_testing(ctx);
    let kind = if (group) party::new_group_kind() else party::new_individual_kind();
    let (party, admin_cap) = party::new(kind, "Test Artist", &clock, ctx);
    clock.destroy_for_testing();
    (party, admin_cap)
}

fun new_shared_party(scenario: &mut ts::Scenario, group: bool): ID {
    let (party, admin_cap) = new_party(group, scenario.ctx());
    let party_id = object::id(&party);
    party.share(&admin_cap, scenario.ctx());
    transfer::public_transfer(admin_cap, ADMIN);
    party_id
}

fun new_vault<Cap: key + store>(
    cap: Cap,
    ctx: &mut TxContext,
): (Vault<Cap>, VaultAdminCap<Cap>) {
    let mut registry = vault::new_registry_for_testing(ctx);
    let (vault, admin_cap) = vault::new(&mut registry, cap, ctx);
    destroy(registry);
    (vault, admin_cap)
}

fun new_vaulted_party(scenario: &mut ts::Scenario): ID {
    let (party, party_admin_cap) = new_party(false, scenario.ctx());
    let party_id = object::id(&party);
    party.share(&party_admin_cap, scenario.ctx());
    let (vault, vault_admin_cap) = new_vault(party_admin_cap, scenario.ctx());
    vault.share();
    transfer::public_transfer(vault_admin_cap, ADMIN);
    party_id
}

fun send_coin<T>(scenario: &mut ts::Scenario, recipient: address, amount: u64): ID {
    let coin = coin::mint_for_testing<T>(amount, scenario.ctx());
    let coin_id = object::id(&coin);
    transfer::public_transfer(coin, recipient);
    coin_id
}

fun ticket<T: key + store>(id: ID): sui::transfer::Receiving<T> {
    ts::receiving_ticket_by_id<T>(id)
}

fun destroy_stake(stake: StakeLike) {
    let StakeLike { id, amount: _ } = stake;
    id.delete()
}

// === Direct-cap object and coin receipt ===

#[test]
fun direct_owned_cap_receives_exact_object_and_emits_payload() {
    let mut scenario = ts::begin(ADMIN);
    let party_id = new_shared_party(&mut scenario, false);

    scenario.next_tx(ADMIN);
    let stake = StakeLike { id: object::new(scenario.ctx()), amount: 5_000 };
    let stake_id = object::id(&stake);
    transfer::public_transfer(stake, party_id.to_address());

    scenario.next_tx(ADMIN);
    {
        let mut party = scenario.take_shared<Party>();
        let admin_cap = scenario.take_from_sender<PartyAdminCap>();
        let received = action::receive(&mut party, &admin_cap, ticket<StakeLike>(stake_id));

        assert_eq!(object::id(&received), stake_id);
        assert_eq!(received.amount, 5_000);
        let events = event::events_by_type<action::ObjectReceivedEvent<StakeLike>>();
        assert_eq!(events.length(), 1);
        let (emitted_party, emitted_object) = action::object_received_event_fields(&events[0]);
        assert_eq!(emitted_party, party_id);
        assert_eq!(emitted_object, stake_id);

        destroy_stake(received);
        scenario.return_to_sender(admin_cap);
        ts::return_shared(party);
    };
    scenario.end();
}

#[test]
fun group_party_receives_an_object() {
    let mut scenario = ts::begin(ADMIN);
    let party_id = new_shared_party(&mut scenario, true);

    scenario.next_tx(ADMIN);
    let coin_id = send_coin<SUI>(&mut scenario, party_id.to_address(), 77);

    scenario.next_tx(ADMIN);
    {
        let mut party = scenario.take_shared<Party>();
        let admin_cap = scenario.take_from_sender<PartyAdminCap>();
        let coin = action::receive(&mut party, &admin_cap, ticket<Coin<SUI>>(coin_id));
        assert_eq!(coin.value(), 77);
        assert_eq!(object::id(&coin), coin_id);
        let events = event::events_by_type<action::ObjectReceivedEvent<Coin<SUI>>>();
        assert_eq!(events.length(), 1);
        let (emitted_party, emitted_object) = action::object_received_event_fields(&events[0]);
        assert_eq!(emitted_party, party_id);
        assert_eq!(emitted_object, coin_id);
        assert_eq!(event::events_by_type<action::ObjectReceivedEvent<StakeLike>>().length(), 0);
        coin.burn_for_testing();
        scenario.return_to_sender(admin_cap);
        ts::return_shared(party);
    };
    scenario.end();
}

#[test]
fun receives_and_merges_coins_with_event_payload() {
    let mut scenario = ts::begin(ADMIN);
    let party_id = new_shared_party(&mut scenario, false);

    scenario.next_tx(ADMIN);
    let first = send_coin<SUI>(&mut scenario, party_id.to_address(), 400);
    let second = send_coin<SUI>(&mut scenario, party_id.to_address(), 600);

    scenario.next_tx(ADMIN);
    {
        let mut party = scenario.take_shared<Party>();
        let admin_cap = scenario.take_from_sender<PartyAdminCap>();
        let received = action::receive_balance<SUI>(
            &mut party,
            &admin_cap,
            vector[ticket<Coin<SUI>>(first), ticket<Coin<SUI>>(second)],
        );
        assert_eq!(received.value(), 1_000);

        let events = event::events_by_type<action::CoinsReceivedEvent<SUI>>();
        assert_eq!(events.length(), 1);
        let (emitted_party, amount, count) = action::coins_received_event_fields(&events[0]);
        assert_eq!(emitted_party, party_id);
        assert_eq!(amount, 1_000);
        assert_eq!(count, 2);

        assert_eq!(balance::destroy_for_testing(received), 1_000);
        scenario.return_to_sender(admin_cap);
        ts::return_shared(party);
    };
    scenario.end();
}

#[test]
fun receives_zero_valued_coins_and_emits_count() {
    let mut scenario = ts::begin(ADMIN);
    let party_id = new_shared_party(&mut scenario, false);

    scenario.next_tx(ADMIN);
    let first = send_coin<SUI>(&mut scenario, party_id.to_address(), 0);
    let second = send_coin<SUI>(&mut scenario, party_id.to_address(), 0);

    scenario.next_tx(ADMIN);
    {
        let mut party = scenario.take_shared<Party>();
        let admin_cap = scenario.take_from_sender<PartyAdminCap>();
        let received = action::receive_balance<SUI>(
            &mut party,
            &admin_cap,
            vector[ticket<Coin<SUI>>(first), ticket<Coin<SUI>>(second)],
        );
        assert_eq!(received.value(), 0);

        let events = event::events_by_type<action::CoinsReceivedEvent<SUI>>();
        assert_eq!(events.length(), 1);
        let (emitted_party, amount, count) = action::coins_received_event_fields(&events[0]);
        assert_eq!(emitted_party, party_id);
        assert_eq!(amount, 0);
        assert_eq!(count, 2);

        assert_eq!(balance::destroy_for_testing(received), 0);
        scenario.return_to_sender(admin_cap);
        ts::return_shared(party);
    };
    scenario.end();
}

#[test, expected_failure(abort_code = EUnauthorized, location = partyos::party)]
fun receive_rejects_a_cap_for_another_party() {
    let mut scenario = ts::begin(ADMIN);
    let party_id = new_shared_party(&mut scenario, false);

    scenario.next_tx(ADMIN);
    let (_other_party, other_cap) = new_party(false, scenario.ctx());
    let coin_id = send_coin<SUI>(&mut scenario, party_id.to_address(), 10);

    scenario.next_tx(ADMIN);
    let mut party = scenario.take_shared<Party>();
    let coin = action::receive(&mut party, &other_cap, ticket<Coin<SUI>>(coin_id));
    coin.burn_for_testing();
    abort
}

/// The framework reports an invalid receiving ticket as a native execution
/// failure, not a stable package abort code.
#[test, expected_failure]
fun receive_rejects_a_ticket_for_another_address() {
    let mut scenario = ts::begin(ADMIN);
    new_shared_party(&mut scenario, false);

    scenario.next_tx(ADMIN);
    let coin_id = send_coin<SUI>(&mut scenario, RECIPIENT, 10);

    scenario.next_tx(ADMIN);
    let mut party = scenario.take_shared<Party>();
    let admin_cap = scenario.take_from_sender<PartyAdminCap>();
    let coin = action::receive(&mut party, &admin_cap, ticket<Coin<SUI>>(coin_id));
    coin.burn_for_testing();
    ts::return_shared(party);
    scenario.return_to_sender(admin_cap);
    scenario.end();
}

#[test, expected_failure(abort_code = action::ENothingToReceive)]
fun receive_balance_rejects_empty_input() {
    let ctx = &mut tx_context::dummy();
    let (mut party, admin_cap) = new_party(false, ctx);
    let balance = action::receive_balance<SUI>(&mut party, &admin_cap, vector[]);
    balance::destroy_for_testing(balance);
    abort
}

// === Direct-cap accumulator redemption ===

#[test]
fun redeems_funds_and_emits_payload() {
    let mut scenario = ts::begin(ADMIN);
    let party_id = new_shared_party(&mut scenario, false);

    scenario.next_tx(ADMIN);
    balance::create_for_testing<SUI>(750).send_funds(party_id.to_address());

    scenario.next_tx(ADMIN);
    {
        let mut party = scenario.take_shared<Party>();
        let admin_cap = scenario.take_from_sender<PartyAdminCap>();
        let redeemed = action::redeem_balance<SUI>(&mut party, &admin_cap, 750);
        assert_eq!(redeemed.value(), 750);

        let events = event::events_by_type<action::FundsRedeemedEvent<SUI>>();
        assert_eq!(events.length(), 1);
        let (emitted_party, amount) = action::funds_redeemed_event_fields(&events[0]);
        assert_eq!(emitted_party, party_id);
        assert_eq!(amount, 750);

        assert_eq!(balance::destroy_for_testing(redeemed), 750);
        scenario.return_to_sender(admin_cap);
        ts::return_shared(party);
    };
    scenario.end();
}

#[test]
fun partial_redemptions_cover_every_locally_reachable_funded_path() {
    let mut scenario = ts::begin(ADMIN);
    let party_id = new_shared_party(&mut scenario, false);

    scenario.next_tx(ADMIN);
    balance::create_for_testing<SUI>(1_000).send_funds(party_id.to_address());

    scenario.next_tx(ADMIN);
    {
        let mut party = scenario.take_shared<Party>();
        let admin_cap = scenario.take_from_sender<PartyAdminCap>();
        let first = action::redeem_balance<SUI>(&mut party, &admin_cap, 400);
        assert_eq!(balance::destroy_for_testing(first), 400);
        scenario.return_to_sender(admin_cap);
        ts::return_shared(party);
    };

    scenario.next_tx(ADMIN);
    {
        let mut party = scenario.take_shared<Party>();
        let admin_cap = scenario.take_from_sender<PartyAdminCap>();
        let remainder = action::redeem_balance<SUI>(&mut party, &admin_cap, 600);
        assert_eq!(balance::destroy_for_testing(remainder), 600);
        scenario.return_to_sender(admin_cap);
        ts::return_shared(party);
    };
    scenario.end();
}

#[test, expected_failure(abort_code = ENoValueToRedeem, location = action)]
fun zero_redemption_aborts() {
    let ctx = &mut tx_context::dummy();
    let (mut party, admin_cap) = new_party(false, ctx);
    let redeemed = action::redeem_balance<SUI>(&mut party, &admin_cap, 0);
    balance::destroy_for_testing(redeemed);
    abort
}

// Accumulator solvency is enforced outside the Move test VM. The actual
// overdraw/rollback and exactly-funded success regression lives in
// e2e/wallet.localnet.ts; expected_failure here would not test that boundary.

/// The test VM's `AccumulatorRoot` view is commit-settled and remains zero even
/// after a test credit. This exercises the only honest local snapshot path.
#[test]
fun funded_accumulator_snapshot_documents_zero_vm_result() {
    let mut scenario = ts::begin(SYSTEM);
    sui::accumulator::create_for_testing(scenario.ctx());
    let party_id = new_shared_party(&mut scenario, false);

    scenario.next_tx(ADMIN);
    balance::create_for_testing<SUI>(123).send_funds(party_id.to_address());

    scenario.next_tx(ADMIN);
    {
        let party = scenario.take_shared<Party>();
        let root = scenario.take_shared<AccumulatorRoot>();
        let settled = balance::settled_funds_value<SUI>(&root, action::inbox_address(&party));
        assert_eq!(settled, 0);
        ts::return_shared(root);
        ts::return_shared(party);
    };
    scenario.end();
}

#[test]
fun inbox_address_is_the_party_id_as_an_address() {
    let ctx = &mut tx_context::dummy();
    let (party, admin_cap) = new_party(false, ctx);
    assert_eq!(action::inbox_address(&party), object::id(&party).to_address());
    destroy(admin_cap);
    destroy(party);
}

// === Vault admin composition (Vault is a dev dependency only) ===

#[test]
fun vault_admin_borrows_calls_action_puts_back_and_borrows_again() {
    let mut scenario = ts::begin(ADMIN);
    let party_id = new_vaulted_party(&mut scenario);

    scenario.next_tx(ADMIN);
    let coin_id = send_coin<SUI>(&mut scenario, party_id.to_address(), 900);

    scenario.next_tx(ADMIN);
    {
        let mut party = scenario.take_shared<Party>();
        let mut vault = scenario.take_shared<Vault<PartyAdminCap>>();
        let vault_admin_cap = scenario.take_from_sender<VaultAdminCap<PartyAdminCap>>();

        let (party_admin_cap, receipt) = vault.borrow_as_admin(&vault_admin_cap);
        let cap_id = object::id(&party_admin_cap);
        let received = action::receive_balance<SUI>(
            &mut party,
            &party_admin_cap,
            vector[ticket<Coin<SUI>>(coin_id)],
        );
        assert_eq!(balance::destroy_for_testing(received), 900);
        vault.put_back(party_admin_cap, receipt);

        let (party_admin_cap_again, receipt_again) = vault.borrow_as_admin(&vault_admin_cap);
        assert_eq!(object::id(&party_admin_cap_again), cap_id);
        assert_eq!(party::party_admin_cap_party_id(&party_admin_cap_again), party_id);
        vault.put_back(party_admin_cap_again, receipt_again);

        scenario.return_to_sender(vault_admin_cap);
        ts::return_shared(vault);
        ts::return_shared(party);
    };
    scenario.end();
}

#[test, expected_failure(abort_code = ENotVaultAdmin, location = vault)]
fun vault_borrow_rejects_a_foreign_vault_admin_cap() {
    let ctx = &mut tx_context::dummy();
    let (_party_a, cap_a) = new_party(false, ctx);
    let (_party_b, cap_b) = new_party(false, ctx);
    let (mut vault_a, _vault_a_admin) = new_vault(cap_a, ctx);
    let (_vault_b, vault_b_admin) = new_vault(cap_b, ctx);
    let (_borrowed, _receipt) = vault_a.borrow_as_admin(&vault_b_admin);
    abort
}

#[test, expected_failure(abort_code = EUnauthorized, location = partyos::party)]
fun action_rejects_a_vault_containing_another_partys_cap() {
    let ctx = &mut tx_context::dummy();
    let (mut target_party, _target_cap) = new_party(false, ctx);
    let (_other_party, other_cap) = new_party(false, ctx);
    let (mut vault, vault_admin_cap) = new_vault(other_cap, ctx);
    let (borrowed_cap, _receipt) = vault.borrow_as_admin(&vault_admin_cap);
    let redeemed = action::redeem_balance<SUI>(&mut target_party, &borrowed_cap, 1);
    balance::destroy_for_testing(redeemed);
    abort
}
