use aiken/builtin
use aiken/dict
use aiken/interval.{Finite, Interval, IntervalBound}
use aiken/list
use aiken/math/rational
use aiken/pairs
use aiken/transaction.{InlineDatum, Input, Output, WithdrawFrom}
use aiken/transaction/certificate.{CredentialDelegation}
use aiken/transaction/credential.{Address, Inline, ScriptCredential}
use aiken/transaction/value.{MintedValue}
use butane/prices
use butane/types
use butane/unsafe
use butane/utils

// All value at the treasury may either be used for burning bad debt, or for spending via governance
// When we burn bad debt, we invoke synthetics.ak's burn endpoint, and we read params in
// When we spend via governance, we destroy a locked governance token, and validate that the datum says to spend the treasury

// Treasury has common function: spending!
// We sum up all inputs from the treasury as the 'Spend Value'
// We specify a 'change output'
// The remainder must be authorized either by the governance or debt redemption
// Governance is not allowed to spend debt, so debt must go into change
// Redemptions may also not spend debt, so debt must be burnt

pub fn treasury_spend(
  inputs: List<Input>,
  outputs: List<Output>,
  mint: MintedValue,
  state_hash: ByteArray,
  mint_script_hash: types.ScriptHash,
  expected_output_idx: Int,
  gov_inp_idx: Int,
  // A spend tx can only use treasury inputs from one type, either from fees or from "only spend"s
  inputs_from_fees: Bool,
) -> Bool {
  let minted = value.from_minted_value(mint)
  let state_cred = ScriptCredential(state_hash)
  let script_inputs =
    list.filter(
      inputs,
      fn(i: Input) { i.output.address.payment_credential == state_cred },
    )
  let gov_inp = unsafe.list_at(script_inputs, gov_inp_idx)
  let other_inputs = list.delete(script_inputs, gov_inp)
  let input_value = {
    let i, acc <- list.foldl(other_inputs, value.zero())
    expect InlineDatum(input_datum) = i.output.datum
    expect types.TreasuryDatum { treas: treas_type } =
      utils.to_monodatum(input_datum)
    expect
      if inputs_from_fees {
        treas_type == types.TreasuryFromFees
      } else {
        treas_type == types.TreasuryOnlySpend
      }
    value.merge(acc, i.output.value)
  }
  expect InlineDatum(raw_gov_datum) = gov_inp.output.datum
  expect types.GovDatum(types.TreasurySpendAuth { out: expected_out_raw }) =
    utils.to_monodatum(raw_gov_datum)
  let expected_out = utils.fake_to_real_out(expected_out_raw)
  let expected_out_value = expected_out.value
  // If only a portion of the value spendable via the gov action is spent, then the remainder must be handled by another gov action
  let leftover_value = {
    let
      policy_id,
      asset_name,
      qty,
      acc,
    <-
      value.reduce(
        value.merge(expected_out_value, value.negate(input_value)),
        value.zero(),
      )
    if qty > 0 {
      value.add(acc, policy_id, asset_name, qty)
    } else {
      acc
    }
  }
  expect [spent_output, ..remaining_outputs] =
    list.drop(outputs, expected_output_idx)
  let expected_change =
    value.merge(input_value, value.negate(spent_output.value))
  let change_datum =
    types.TreasuryDatum {
      treas: if inputs_from_fees {
        types.TreasuryFromFees
      } else {
        types.TreasuryOnlySpend
      },
    }

  let valid_change =
    fn(change_output: Output) { and {
        change_output.address == Address(
          state_cred,
          Some(Inline(ScriptCredential(mint_script_hash))),
        ),
        change_output.datum == InlineDatum(change_datum),
        change_output.value == expected_change,
      } }

  if leftover_value != value.zero() {
    let remaining_gov_output =
      if expected_change != value.zero() {
        expect [change_output, gov_output, ..] = remaining_outputs
        expect valid_change(change_output)
        gov_output
      } else {
        builtin.head_list(remaining_outputs)
      }
    expect Output {
      value: remaining_gov_value,
      address: Address { payment_credential: remaining_gov_pc, .. },
      datum: InlineDatum(raw_remaining_gov_datum),
      ..
    } = remaining_gov_output
    expect types.GovDatum(types.TreasurySpendAuth { out: next_expected_out_raw }): types.MonoDatum =
      raw_remaining_gov_datum
    let next_expected_out = utils.fake_to_real_out(next_expected_out_raw)
    let remaining_expected_gov_out =
      Output { ..expected_out, value: leftover_value }
    let expected_this_action_out =
      Output {
        ..expected_out,
        value: value.merge(input_value, value.negate(expected_change)),
      }
    and {
      // Created gov output is a valid gov action
      (value.without_lovelace(remaining_gov_value) == value.from_asset(
        mint_script_hash,
        types.gov_lock_token_name,
        1,
      ))?,
      (remaining_gov_pc == state_cred)?,
      // Outputs related to the spend are as expected
      spent_output == expected_this_action_out,
      next_expected_out == remaining_expected_gov_out,
      // Not minting or burning anything
      utils.mints_nothing_here(minted, mint_script_hash),
    }
  } else {
    expect [spent_output, ..remaining_outputs] =
      list.drop(outputs, expected_output_idx)
    expect
      expected_change == value.zero() || valid_change(
        builtin.head_list(remaining_outputs),
      )
    and {
      // Spent output has the governance-requested value
      (spent_output == expected_out)?,
      // Gov lock token is burned with no other mints at the synthetics script
      utils.only_mints_this(
        minted,
        mint_script_hash,
        types.gov_lock_token_name,
        -1,
      )?,
      // Gov input contains lock token
      utils.gov_has_lock_token(gov_inp, mint_script_hash)?,
    }
  }
}

pub fn treasury_mint(
  inputs,
  outputs: List<Output>,
  mint,
  state_hash: ByteArray,
  mint_script_hash: types.ScriptHash,
  expected_output_idx: Int,
) {
  let (synth_minted_name, synth_minted_qty, gov_minted_qty) = {
    expect [Pair(first_token, first_minted), Pair(second_token, second_minted)] =
      mint
        |> value.from_minted_value
        |> value.tokens(mint_script_hash)
        |> dict.to_pairs
    if first_token == types.gov_lock_token_name {
      (second_token, second_minted, first_minted)
    } else if second_token == types.gov_lock_token_name {
      (first_token, first_minted, second_minted)
    } else {
      fail @"Gov lock token not in mint"
    }
  }
  let state_cred = ScriptCredential(state_hash)
  expect [gov_inp] =
    list.filter(
      inputs,
      fn(i: Input) { i.output.address.payment_credential == state_cred },
    )

  expect InlineDatum(raw_gov_datum) = gov_inp.output.datum
  expect types.GovDatum(types.TreasuryMintAuth {
    asset: expected_synthetic,
    amount: expected_amount,
  }) = utils.to_monodatum(raw_gov_datum)

  let synth_output = unsafe.list_at(outputs, expected_output_idx)

  and {
    // Datum is correct
    synth_output.datum == InlineDatum(
      types.TreasuryDatum { treas: types.TreasuryFromFees },
    ),
    // Change output is a valid datum at the correct address:
    synth_output.address.payment_credential == state_cred,
    // Minting the right amount of the right synthetic
    synth_minted_name == expected_synthetic,
    synth_minted_qty == expected_amount,
    // All of the minted synths are sent to the expected output (with no dust)
    ( synth_output.value |> value.without_lovelace() ) == value.from_asset(
      mint_script_hash,
      expected_synthetic,
      expected_amount,
    ),
    // Gov lock token is burned
    gov_minted_qty == -1,
    // Gov input contains lock token
    utils.gov_has_lock_token(gov_inp, mint_script_hash)?,
  }
}

pub fn treasury_create_debt(
  inputs: List<Input>,
  reference_inputs: List<Input>,
  outputs: List<Output>,
  mint: MintedValue,
  state_hash: ByteArray,
  mint_script_hash: types.ScriptHash,
  expected_output_idx: Int,
) {
  let minted = value.from_minted_value(mint)
  let state_cred = ScriptCredential(state_hash)
  expect [gov_inp] =
    list.filter(
      inputs,
      fn(i: Input) { i.output.address.payment_credential == state_cred },
    )

  expect InlineDatum(raw_gov_datum) = gov_inp.output.datum
  expect types.GovDatum(types.TreasuryCreateDebtAuth(expected_debt_datum)) =
    utils.to_monodatum(raw_gov_datum)
  let debt_output = unsafe.list_at(outputs, expected_output_idx)
  let expected_datum =
    types.TreasuryDatum {
      treas: types.TreasuryWithDebt {
        debt: expected_debt_datum,
        creation_time: None,
      },
    }

  expect [
    types.ParamsData {
      synthetic: params_synth,
      params: types.LiveParams{params: types.ActiveParams {
        collateral_assets,
        ..
      }},
    },
  ] = utils.params_from_refs(reference_inputs, mint_script_hash)
  and {
    // Output is a valid datum at the correct address:
    (debt_output.address == Address(
      state_cred,
      Some(Inline(ScriptCredential(mint_script_hash))),
    ))?,
    (debt_output.datum == InlineDatum(expected_datum))?,
    // Gov lock token isn't burned, it's transferred to the created debt
    (value.quantity_of(
      debt_output.value,
      mint_script_hash,
      types.gov_lock_token_name,
    ) == 1)?,
    utils.mints_nothing_here(minted, mint_script_hash)?,
    // Gov input contains lock token
    utils.gov_has_lock_token(gov_inp, mint_script_hash)?,
    // Synthetic name matches with referenced params
    (params_synth == expected_debt_datum.asset)?,
    // All tokens in the debt value are valid collateral assets
    {
      let p, a, _, acc <- value.reduce(debt_output.value, True)
      acc && or {
        p == mint_script_hash && a == types.gov_lock_token_name,
        list.has(
          collateral_assets,
          types.AssetClass { policy_id: p, asset_name: a },
        ),
      }
    }?,
  }
}

// If the treasury has debt, anybody can redeem it. It's assumed that the debt was created via a gov action or via bad debt and therefore redemptions against it are authorized
pub fn treasury_redeem(
  inputs,
  reference_inputs,
  redeemers,
  mint,
  outputs,
  validity_range,
  state_script_hash: ByteArray,
  mint_script_hash: types.ScriptHash,
  price_feed_script_hash: ByteArray,
  lock_burned: Option<Bool>,
  inputs_from_fees: Bool,
) {
  let state_cred = ScriptCredential(state_script_hash)
  expect Interval {
    lower_bound: IntervalBound { bound_type: Finite(valid_from), .. },
    ..
  } = validity_range
  let inputs_here =
    list.filter(
      inputs,
      fn(i: Input) { i.output.address.payment_credential == state_cred },
    )

  let minted_here =
    mint
      |> value.from_minted_value
      |> value.tokens(mint_script_hash)
      |> dict.to_pairs

  let (Pair(burn_token, burn_amount_neg), lock_mint_pair) =
    when lock_burned is {
      Some(burned_first) -> {
        expect [a, b] = minted_here
        if burned_first {
          (b, Some(a))
        } else {
          (a, Some(b))
        }
      }
      None -> {
        expect [a] = minted_here
        (a, None)
      }
    }
  let burn_amount = -burn_amount_neg
  let (debt_value_with_lock, debt_amount, num_lock_spent) = {
    let
      i,
      (acc_debt_value, acc_debt, acc_lock_spent),
    <- list.foldl(inputs_here, (value.zero(), 0, 0))
    expect InlineDatum(input_datum) = i.output.datum
    expect types.TreasuryDatum { treas }: types.MonoDatum = input_datum
    when treas is {
      types.TreasuryWithDebt {
        debt: types.TreasuryDebt { amount: this_debt_amount, asset: debt_asset },
        creation_time,
      } -> {
        expect and {
            debt_asset == burn_token,
            when creation_time is {
              Some(creation_time_num) ->
                creation_time_num + types.milliseconds_in_week <= valid_from
              None -> True
            },
          }
        (
          value.merge(acc_debt_value, i.output.value),
          acc_debt + this_debt_amount,
          // We expect that all TreasuryWithDebt inputs have a lock token
          acc_lock_spent + 1,
        )
      }
      _ -> {
        expect
          if inputs_from_fees {
            treas == types.TreasuryFromFees
          } else {
            treas == types.TreasuryOnlyRedeem
          }
        (value.merge(acc_debt_value, i.output.value), acc_debt, acc_lock_spent)
      }
    }
  }
  let debt_value =
    value.add(
      debt_value_with_lock,
      mint_script_hash,
      types.gov_lock_token_name,
      -num_lock_spent,
    )
  expect [
    types.ParamsData {
      params: types.LiveParams{params: types.ActiveParams {
        weights: cdp_weights,
        collateral_assets: cdp_assets,
        denominator: cdp_denominator,
        max_proportions: cdp_max_proportions,
        redemption_share,
        ..
      }},
      synthetic: synthetic_name,
    },
  ] = utils.params_from_refs(reference_inputs, mint_script_hash)
  let price_feed_redeemer =
    utils.to_pricefeedredeemer(
      unsafe.unsome(
        pairs.get_first(
          redeemers,
          WithdrawFrom(utils.stake_cred_from_hash(price_feed_script_hash)),
        ),
      ),
    )
  expect [
    types.PriceFeed {
      collateral_prices: p_list,
      denominator: p_denom,
      synthetic: price_feed_synthetic,
      validity: p_validity_range,
    },
  ]: List<types.PriceFeed> = list.map(price_feed_redeemer, fn(p) { p.data })

  // Tx validity range is a subset of the price feed's validity range
  expect utils.check_price_feed_validity(p_validity_range, validity_range)

  let
    debt_collateral_value,
    _,
  <-
    prices.get_collateral_finances(
      p_list,
      p_denom,
      debt_value,
      cdp_assets,
      cdp_weights,
      cdp_denominator,
      cdp_max_proportions,
      // We only care about the value so we can ignore the synthetic amount
      1,
    )
  let debt_collateral_value = debt_collateral_value |> rational.truncate
  let redeeming_collateral_value =
    burn_amount * redemption_share / types.bp_precision
  let leftover_debt = debt_amount - burn_amount
  let leftover_collateral_value =
    debt_collateral_value - redeeming_collateral_value

  let (valid_change_value, remaining_outputs) =
    if leftover_collateral_value > 0 {
      expect Output {
        datum: InlineDatum(change_datum_raw),
        value: change_value,
        address: Address {
          payment_credential: ScriptCredential(change_script_hash),
          ..
        },
        ..
      } = builtin.head_list(outputs)

      expect types.TreasuryDatum { treas }: types.MonoDatum = change_datum_raw
      let valid_change_datum =
        if inputs_from_fees {
          (treas == types.TreasuryFromFees)?
        } else {
          (treas == types.TreasuryOnlyRedeem)?
        }

      let
        change_collateral_value_rat,
        _,
      <-
        prices.get_collateral_finances(
          p_list,
          p_denom,
          change_value,
          cdp_assets,
          cdp_weights,
          cdp_denominator,
          cdp_max_proportions,
          // We only care about the value so we can ignore the synthetic amount
          1,
        )

      let change_collateral_value =
        change_collateral_value_rat |> rational.truncate

      (and {
          (change_script_hash == state_script_hash)?,
          (change_collateral_value >= leftover_collateral_value)?,
          valid_change_datum?,
          {
            let pol, tok, qty, acc <- value.reduce(change_value, True)
            (acc && value.quantity_of(debt_value, pol, tok) >= qty)?
          },
        }, builtin.tail_list(outputs))
    } else {
      (True, outputs)
    }

  let valid_leftover_debt =
    if leftover_debt > 0 {
      expect Output {
        datum: InlineDatum(change_debt_datum_raw),
        value: change_debt_value,
        address: Address {
          payment_credential: ScriptCredential(change_debt_script_hash),
          ..
        },
        ..
      } = builtin.head_list(remaining_outputs)
      expect types.TreasuryDatum{treas: types.TreasuryWithDebt {
        debt: types.TreasuryDebt {
          amount: change_debt_amount,
          asset: change_debt_asset,
        },
        creation_time,
      }}: types.MonoDatum = change_debt_datum_raw
      and {
        (creation_time == None)?,
        (change_debt_amount == leftover_debt)?,
        (change_debt_asset == burn_token)?,
        (value.without_lovelace(change_debt_value) == value.from_asset(
          mint_script_hash,
          types.gov_lock_token_name,
          1,
        ))?,
        (value.lovelace_of(change_debt_value) <= types.max_min_ada)?,
        (change_debt_script_hash == state_script_hash)?,
        or {
          num_lock_spent == 1,
          // If there's leftover debt, we reserve one lock token for it
          lock_mint_pair == Some(
            Pair(types.gov_lock_token_name, -(num_lock_spent - 1)),
          ),
        }?,
      }
    } else {
      // If there's no leftover debt, all lock tokens in the inputs must be burned
      (lock_mint_pair == Some(Pair(types.gov_lock_token_name, -num_lock_spent)))?
    }

  and {
    valid_change_value?,
    valid_leftover_debt?,
    (synthetic_name == burn_token)?,
    (price_feed_synthetic == burn_token)?,
    (leftover_collateral_value >= 0)?,
    (leftover_debt >= 0)?,
  }
}

pub fn treasury_stake_update(
  inputs,
  mint,
  certificates,
  state_hash: ByteArray,
  mint_script_hash: types.ScriptHash,
) {
  let minted = value.from_minted_value(mint)
  let state_cred = ScriptCredential(state_hash)
  expect [gov_inp] =
    list.filter(
      inputs,
      fn(i: Input) { i.output.address.payment_credential == state_cred },
    )
  expect InlineDatum(raw_gov_datum) = gov_inp.output.datum
  expect types.GovDatum(types.TreasuryStakeUpdate { delegatee: gov_delegatee }): types.MonoDatum =
    raw_gov_datum
  and {
    certificates == [
      CredentialDelegation {
        delegator: Inline(ScriptCredential(mint_script_hash)),
        delegatee: gov_delegatee,
      },
    ],
    utils.only_mints_this(
      minted,
      mint_script_hash,
      types.gov_lock_token_name,
      -1,
    )?,
    // Gov input contains lock token
    utils.gov_has_lock_token(gov_inp, mint_script_hash)?,
  }
}

pub fn treasury_reward_withdraw(
  inputs,
  mint,
  outputs,
  withdrawals,
  state_hash: ByteArray,
  mint_script_hash: types.ScriptHash,
) {
  let state_cred = ScriptCredential(state_hash)
  expect [] =
    list.filter(
      inputs,
      fn(i: Input) { i.output.address.payment_credential == state_cred },
    )
  expect [
    Output {
      value: withdrawn_value,
      datum: InlineDatum(raw_withdraw_datum),
      address: withdraw_address,
      reference_script: None,
    },
    ..
  ] = outputs
  expect withdraw_datum: types.MonoDatum = raw_withdraw_datum
  expect Some(withdrawn_lovelace) =
    withdrawals |> pairs.get_first(Inline(ScriptCredential(mint_script_hash)))
  and {
    utils.mints_nothing_here(mint |> value.from_minted_value, mint_script_hash),
    withdraw_address == Address(
      ScriptCredential(state_hash),
      Some(Inline(ScriptCredential(mint_script_hash))),
    ),
    withdraw_datum == types.TreasuryDatum { treas: types.TreasuryFromFees },
    withdrawn_value == value.from_lovelace(withdrawn_lovelace),
  }
}
