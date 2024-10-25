use aiken/interval.{Finite, Interval, IntervalBound}
use aiken/list
use aiken/math/rational
use aiken/pairs
use aiken/transaction.{InlineDatum, Input, Output, WithdrawFrom}
use aiken/transaction/credential.{Address, Credential, Inline, ScriptCredential}
use aiken/transaction/value.{Value}
use butane/prices
use butane/types
use butane/unsafe
use butane/utils

fn check_inputs(
  valid_to: Int,
  synthetic_name: ByteArray,
  cdp_price_list: List<Int>,
  cdp_price_denom: Int,
  cdp_collateral,
  cdp_weights,
  cdp_denominator,
  cdp_max_proportions,
  cdp_interest_rates,
  state_cred: Credential,
  mint_script_hash: ByteArray,
  inputs: List<Input>,
  accv: Value,
  accs: Int,
  count: Int,
) {
  when inputs is {
    [] -> (accv, accs, count)
    [inp, ..other_inputs] -> {
      let Input {
        output: Output {
          address: Address { payment_credential: inp_cred, .. },
          value: cdp_value,
          datum,
          ..
        },
        ..
      } = inp
      if inp_cred == state_cred {
        expect InlineDatum(this_raw_datum) = datum
        expect types.CDP {
          synthetic_asset: cdp_synthetic_name,
          synthetic_amount: cdp_synthetic_amount,
          start_time: cdp_start_time,
          ..
        } = utils.to_monodatum(this_raw_datum)
        let fee_percent =
          utils.calculate_fee_percent(
            cdp_interest_rates,
            cdp_start_time,
            valid_to,
          )
        let fee_in_synthetic =
          fee_percent * cdp_synthetic_amount / types.bp_precision / types.milliseconds_in_year
        let cr, _ <-
          prices.get_collateral_finances(
            p_list: cdp_price_list,
            p_dom: cdp_price_denom,
            v: cdp_value
              |> value.add(mint_script_hash, types.cdp_lock_token_name, -1),
            assets: cdp_collateral,
            w_list: cdp_weights,
            w_dom: cdp_denominator,
            max_proportions_list: cdp_max_proportions,
            synth_amount: cdp_synthetic_amount + fee_in_synthetic,
            callback: _,
          )
        expect and {
            (cdp_synthetic_name == synthetic_name)?,
            (( cr |> rational.compare(rational.from_int(1)) ) == Less)?,
          }
        check_inputs(
          valid_to,
          synthetic_name,
          cdp_price_list,
          cdp_price_denom,
          cdp_collateral,
          cdp_weights,
          cdp_denominator,
          cdp_max_proportions,
          cdp_interest_rates,
          state_cred,
          mint_script_hash,
          other_inputs,
          value.merge(accv, cdp_value),
          accs + cdp_synthetic_amount,
          count + 1,
        )
      } else {
        check_inputs(
          valid_to,
          synthetic_name,
          cdp_price_list,
          cdp_price_denom,
          cdp_collateral,
          cdp_weights,
          cdp_denominator,
          cdp_max_proportions,
          cdp_interest_rates,
          state_cred,
          mint_script_hash,
          other_inputs,
          accv,
          accs,
          count,
        )
      }
    }
  }
}

pub fn bad_debt(
  inputs,
  outputs,
  reference_inputs,
  redeemers,
  validity_range,
  mint,
  state_script_hash: ByteArray,
  price_feed_script_hash: ByteArray,
  mint_script_hash: types.ScriptHash,
  treasury_out_idx: Int,
) {
  let state_cred = ScriptCredential(state_script_hash)
  expect Interval {
    upper_bound: IntervalBound { bound_type: Finite(valid_to), .. },
    ..
  } = validity_range
  expect [
    types.ParamsData {
      params: types.LiveParams{params: types.ActiveParams {
        weights: cdp_weights,
        collateral_assets: cdp_collateral,
        denominator: cdp_denominator,
        max_proportions: cdp_max_proportions,
        interest_rates: cdp_interest_rates,
        ..
      }},
      synthetic: synthetic_name,
    },
  ] = utils.params_from_refs(reference_inputs, mint_script_hash)
  let price_feed_redeemer_raw =
    unsafe.unsome(
      pairs.get_first(
        redeemers,
        WithdrawFrom(utils.stake_cred_from_hash(price_feed_script_hash)),
      ),
    )
  let price_feed_redeemer = utils.to_pricefeedredeemer(price_feed_redeemer_raw)
  expect [
    types.PriceFeed {
      collateral_prices: cdp_price_list,
      denominator: cdp_price_denom,
      synthetic: pricefeed_synthetic,
      validity: pricefeed_validity_range,
    },
  ]: List<types.PriceFeed> = list.map(price_feed_redeemer, fn(p) { p.data })

  // Tx validity range is a subset of the price feed's validity range
  expect
    utils.check_price_feed_validity(pricefeed_validity_range, validity_range)

  let (input_value, burning_synthetics, count) =
    check_inputs(
      valid_to,
      synthetic_name,
      cdp_price_list,
      cdp_price_denom,
      cdp_collateral,
      cdp_weights,
      cdp_denominator,
      cdp_max_proportions,
      cdp_interest_rates,
      state_cred,
      mint_script_hash,
      inputs,
      value.zero(),
      0,
      0,
    )
  let expected_value =
    input_value
      |> value.add(mint_script_hash, types.cdp_lock_token_name, -count)
      |> value.add(mint_script_hash, types.gov_lock_token_name, 1)
  let minted_value =
    value.from_asset(mint_script_hash, types.cdp_lock_token_name, -count)
      |> value.add(mint_script_hash, types.gov_lock_token_name, 1)
      |> value.tokens(mint_script_hash)
  expect Output {
    value: treasury_value,
    datum: InlineDatum(raw_treasury_datum),
    address: treasury_receipt_address,
    ..
  } = outputs |> unsafe.list_at(treasury_out_idx)
  expect types.TreasuryDatum{treas: types.TreasuryWithDebt {
    debt: types.TreasuryDebt {
      amount: treasury_debt_amount,
      asset: treasury_debt_asset,
    },
    creation_time,
  }}: types.MonoDatum = raw_treasury_datum
  and {
    (creation_time == Some(valid_to))?,
    (treasury_receipt_address == Address(
      state_cred,
      Some(Inline(ScriptCredential(mint_script_hash))),
    ))?,
    (( mint |> value.from_minted_value |> value.tokens(mint_script_hash) ) == minted_value)?,
    (treasury_value == expected_value)?,
    (treasury_debt_amount == burning_synthetics)?,
    (pricefeed_synthetic == synthetic_name)?,
    (treasury_debt_asset == pricefeed_synthetic)?,
  }
}
