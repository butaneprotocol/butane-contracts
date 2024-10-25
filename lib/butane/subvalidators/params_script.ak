use aiken/builtin
use aiken/bytearray
use aiken/dict
use aiken/interval.{Finite, Interval, IntervalBound}
use aiken/list
use aiken/math
use aiken/option
use aiken/pairs
use aiken/transaction.{
  InlineDatum, Input, Output, Redeemer, ScriptPurpose, ValidityRange,
  WithdrawFrom,
}
use aiken/transaction/credential.{Address, ScriptCredential}
use aiken/transaction/value.{MintedValue}
use butane/types
use butane/unsafe
use butane/utils

pub fn params_init(
  mint,
  outputs,
  inputs: List<Input>,
  validity_range,
  mint_script_hash: types.ScriptHash,
  state_script_hash: types.ScriptHash,
  oidx: Int,
  fee_token: types.AssetClass,
) {
  expect [gov_inp] =
    inputs
      |> list.filter(
          fn(inp) {
            inp.output.address.payment_credential == ScriptCredential(
              state_script_hash,
            )
          },
        )
  expect InlineDatum(raw_gov_datum) = gov_inp.output.datum
  // expect gov_datum: ParamsGovDatum = raw_gov_datum
  expect types.GovDatum(types.NewParamsAuth { params, asset: expected_asset }) =
    utils.to_monodatum(raw_gov_datum)
  let expected_params_d: Data = params
  let (param_token_name, param_minted_qty, gov_minted_qty) = {
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
      fail @"Invalid lock token"
    }
  }
  expect Output {
    address: Address { payment_credential, .. },
    value: params_value,
    datum: InlineDatum(raw_actual_params),
    ..
  } = outputs |> unsafe.list_at(oidx)
  expect types.ParamsWrapper(actual_params) =
    utils.to_monodatum(raw_actual_params)
  expect types.LiveParams{params: types.ActiveParams {
    collateral_assets: p_collateral_assets,
    weights: p_weights,
    denominator: p_denominator,
    minimum_outstanding_synthetic: p_min_outstanding,
    interest_rates: p_interest_rates,
    fee_token_discount: p_fee_token_discount,
    max_liquidation_return: p_max_return,
    treasury_liquidation_share: p_treasury_share,
    redemption_share: p_redemption_share,
    max_proportions: p_max_proportions,
    staking_interest_rates: p_staking_interest_rates,
  }} = actual_params
  let data_actual_params: Data = actual_params
  let valid_output_value =
    ( params_value |> value.without_lovelace() ) == value.from_asset(
      mint_script_hash,
      param_token_name,
      1,
    )

  expect [
    (p_first_interest_time, p_first_rate),
    (p_max_interest_time, p_max_rate),
  ] = p_interest_rates

  expect [(p_first_staking_time, p_first_staking_rate)] =
    p_staking_interest_rates

  expect Interval {
    lower_bound: IntervalBound { bound_type: Finite(valid_from), .. },
    ..
  } = validity_range

  and {
    // Params token name is in correct format (contains the "p_" prefix followed by the correct synthetic name)
    (param_token_name == bytearray.concat(types.params_prefix, expected_asset))?,
    // Synthetic name isn't a reserved name or invalid
    (expected_asset != types.cdp_lock_token_name)?,
    (expected_asset != types.gov_lock_token_name)?,
    (bytearray.take(expected_asset, types.params_prefix_length) != types.params_prefix)?,
    (bytearray.take(expected_asset, types.debt_prefix_length) != types.debt_prefix)?,
    // Minting one params token
    (param_minted_qty == 1)?,
    // Burning one gov lock token
    (gov_minted_qty == -1)?,
    // Sending to this script
    (payment_credential == ScriptCredential(state_script_hash))?,
    valid_output_value?,
    // Gov input contains lock token
    utils.gov_has_lock_token(gov_inp, mint_script_hash)?,
    (expected_params_d == data_actual_params)?,
    // Collateral assets are sorted by asset class and no duplicates (same as in values)
    (list.sort(p_collateral_assets, utils.compare_asset_classes) == p_collateral_assets)?,
    utils.sorted_list_is_unique(p_collateral_assets)?,
    // The synthetic is not in the list of collateral assets
    !list.has(
      p_collateral_assets,
      types.AssetClass {
        policy_id: mint_script_hash,
        asset_name: expected_asset,
      },
    )?,
    // Collateral assets contain ADA and BTN (the weights can be
    // set to be very high to indicate that they arent't to be used as collateral, 
    // they just need to be in the list for the price feeds)
    (list.at(p_collateral_assets, 0) == Some(
      types.AssetClass {
        policy_id: value.ada_policy_id,
        asset_name: value.ada_asset_name,
      },
    ))?,
    list.has(p_collateral_assets, fee_token)?,
    // All weights are > 1
    (p_denominator > 0)?,
    list.all(p_weights, fn(a) { a > p_denominator })?,
    // Length checks
    (list.length(p_weights) == list.length(p_collateral_assets))?,
    (list.length(p_max_proportions) == list.length(p_collateral_assets))?,
    // Max proportions are all positive
    list.all(p_max_proportions, fn(p) { p > 0 })?,
    // The denominator is the minimal possible denominator
    utils.is_minimal_denom(p_weights, p_denominator)?,
    (p_min_outstanding > 0)?,
    (p_first_rate > 0)?,
    (p_first_staking_rate > 0)?,
    (p_first_staking_rate <= p_first_rate)?,
    // Interest rate start time is the lower bound of the tx validity range (negative to ensure that the most recent rate is the first one in the list, since lists of pairs are maps sorted by keys)
    (p_first_interest_time == -valid_from)?,
    (p_first_staking_time == -valid_from)?,
    (p_max_interest_time == 0)?,
    (p_max_rate == p_first_rate)?,
    // Fee token discount is between 0 and 10_000
    (p_fee_token_discount >= 0 && p_fee_token_discount <= types.bp_precision)?,
    // Max return is greater than 1 (in basis points)
    p_max_return > types.bp_precision,
    // Treasury liquidation share is between 0 and 1 (in basis points)
    p_treasury_share > 0,
    p_treasury_share < types.bp_precision,
    // Redemption share is between 0 and 1 (in basis points)
    p_redemption_share > 0,
    p_redemption_share < types.bp_precision,
  }
}

pub fn params_update(
  mint,
  outputs,
  validity_range: ValidityRange,
  inputs: List<Input>,
  mint_script_hash: types.ScriptHash,
  state_script_hash: types.ScriptHash,
  oidx: Int,
  reverse_order: Bool,
) -> Bool {
  let (
    gov_inp,
    Input {
      output: Output { datum: param_inp_datum, value: param_inp_value, .. },
      ..
    },
  ) = {
    let filtered_inputs =
      inputs
        |> list.filter(
            fn(inp) {
              inp.output.address.payment_credential == ScriptCredential(
                state_script_hash,
              )
            },
          )
    expect [a, b] = filtered_inputs
    if reverse_order {
      (a, b)
    } else {
      (b, a)
    }
  }
  let minted = value.from_minted_value(mint)

  expect InlineDatum(raw_gov_datum) = gov_inp.output.datum
  expect types.GovDatum(types.UpdateParamsAuth {
    asset: synthetic_asset,
    action,
  }) = utils.to_monodatum(raw_gov_datum)

  let expected_lock_token =
    bytearray.concat(types.params_prefix, synthetic_asset)

  expect InlineDatum(raw_params_datum) = param_inp_datum

  expect types.ParamsWrapper(types.LiveParams { params: old_params }) =
    utils.to_monodatum(raw_params_datum)
  let types.ActiveParams {
    collateral_assets: old_collateral_assets,
    weights: old_weights,
    denominator: old_denominator,
    interest_rates: old_rates,
    max_proportions: old_max_proportions,
    staking_interest_rates: old_staking_rates,
    ..
  } = old_params
  let expected_params: types.Params =
    when action is {
      types.NewCollateral {
        index,
        collateral_asset,
        weight_numerator,
        weight_denominator,
        max_proportion,
      } -> {
        expect and {
            // Adding a new collateral asset
            list.has(old_collateral_assets, collateral_asset) == False,
            // Not using the synth as collateral
            types.AssetClass {
              policy_id: mint_script_hash,
              asset_name: synthetic_asset,
            } != collateral_asset,
            // Weight > 1
            weight_numerator > weight_denominator,
            // Max proportion > 0
            max_proportion > 0,
          }
        let (new_weights, new_denominator) =
          if weight_denominator == old_denominator {
            (
              utils.list_insert_at(old_weights, index, weight_numerator),
              old_denominator,
            )
          } else {
            let lcm = utils.lcm(weight_denominator, old_denominator)
            (
              utils.list_insert_at(
                list.map(old_weights, fn(w) { w * lcm / old_denominator }),
                index,
                weight_numerator * lcm / weight_denominator,
              ),
              lcm,
            )
          }
        let new_collateral_assets =
          utils.list_insert_at(old_collateral_assets, index, collateral_asset)
        // The collateral list remains sorted
        expect
          new_collateral_assets == list.sort(
            [collateral_asset, ..old_collateral_assets],
            utils.compare_asset_classes,
          )
        types.LiveParams {
          params: types.ActiveParams {
            ..old_params,
            collateral_assets: new_collateral_assets,
            weights: new_weights,
            denominator: new_denominator,
            max_proportions: utils.list_insert_at(
              old_max_proportions,
              index,
              max_proportion,
            ),
          },
        }
      }
      types.UpdateWeight {
        collateral_asset_idx,
        weight_numerator,
        weight_denominator,
      } -> {
        expect and {
            // Weight > 1
            weight_numerator > weight_denominator,
            // Index is in bounds
            list.length(old_weights) > collateral_asset_idx,
          }
        let (new_weights, new_denominator) =
          if weight_denominator == old_denominator {
            (
              list.indexed_map(
                old_weights,
                fn(i, w) {
                  if i == collateral_asset_idx {
                    weight_numerator
                  } else {
                    w
                  }
                },
              ),
              old_denominator,
            )
          } else {
            let lcm = utils.lcm(weight_denominator, old_denominator)
            (
              list.indexed_map(
                old_weights,
                fn(i, w) {
                  if i == collateral_asset_idx {
                    weight_numerator * lcm / weight_denominator
                  } else {
                    w * lcm / old_denominator
                  }
                },
              ),
              lcm,
            )
          }
        types.LiveParams {
          params: types.ActiveParams {
            ..old_params,
            weights: new_weights,
            denominator: new_denominator,
          },
        }
      }
      types.UpdateInterest { interest_rate } -> {
        expect interest_rate > 0
        expect Interval {
          lower_bound: IntervalBound { bound_type: Finite(valid_from), .. },
          upper_bound: IntervalBound { bound_type: Finite(valid_to), .. },
        } = validity_range
        expect Some((last_update, _)) = list.head(old_rates)
        expect Some((_, old_max)) = list.last(old_rates)
        expect Some(rates_no_max) = list.init(old_rates)

        expect and {
            // Interest history is in reverse-chronological order 
            valid_from > -last_update,
            // Validity range is less than a day
            valid_to - valid_from < types.milliseconds_in_day,
          }

        let new_rates =
          list.push(
            if list.length(rates_no_max) == types.num_stored_interest_rates {
              list.init(rates_no_max) |> option.or_else([])
            } else {
              rates_no_max
            },
            (-valid_from, interest_rate),
          )
            |> list.concat([(0, math.max(old_max, interest_rate))])
        types.LiveParams {
          params: types.ActiveParams { ..old_params, interest_rates: new_rates },
        }
      }

      types.UpdateMinOutstanding { min_outstanding } -> {
        expect min_outstanding > 0
        types.LiveParams {
          params: types.ActiveParams {
            ..old_params,
            minimum_outstanding_synthetic: min_outstanding,
          },
        }
      }

      types.UpdateMaxProportions { max_proportions } -> {
        expect and {
            list.all(max_proportions, fn(p) { p > 0 }),
            list.length(max_proportions) == list.length(old_max_proportions),
          }
        types.LiveParams {
          params: types.ActiveParams {
            ..old_params,
            max_proportions: max_proportions,
          },
        }
      }

      types.UpdateMaxLiquidationReturn { max_return } -> {
        // Max return is greater than 1 (in basis points)
        expect max_return > types.bp_precision
        types.LiveParams {
          params: types.ActiveParams {
            ..old_params,
            max_liquidation_return: max_return,
          },
        }
      }

      types.UpdateTreasuryLiquidationShare { share } -> {
        // Treasury liquidation share is between 0 and 1 (in basis points)
        expect share > 0 && share < types.bp_precision
        types.LiveParams {
          params: types.ActiveParams {
            ..old_params,
            treasury_liquidation_share: share,
          },
        }
      }

      types.UpdateRedemptionShare { share } -> {
        // Redemption share is between 0 and 1 (in basis points)
        expect share > 0 && share < types.bp_precision
        types.LiveParams {
          params: types.ActiveParams { ..old_params, redemption_share: share },
        }
      }

      types.UpdateFeeTokenDiscount { discount } -> {
        expect discount >= 0 && discount <= types.bp_precision
        types.LiveParams {
          params: types.ActiveParams {
            ..old_params,
            fee_token_discount: discount,
          },
        }
      }

      types.UpdateStakingInterest { interest_rate } -> {
        expect interest_rate > 0
        expect Interval {
          lower_bound: IntervalBound { bound_type: Finite(valid_from), .. },
          upper_bound: IntervalBound { bound_type: Finite(valid_to), .. },
        } = validity_range
        expect Some((last_update, _)) = list.head(old_staking_rates)

        expect and {
            // Interest history is in reverse-chronological order 
            valid_from > -last_update,
            // Validity range is less than a day
            valid_to - valid_from < types.milliseconds_in_day,
          }
        let to_push =
          if list.length(old_staking_rates) == types.num_stored_interest_rates {
            list.init(old_staking_rates) |> option.or_else([])
          } else {
            old_staking_rates
          }

        let new_rates = list.push(to_push, (-valid_from, interest_rate))
        types.LiveParams {
          params: types.ActiveParams {
            ..old_params,
            staking_interest_rates: new_rates,
          },
        }
      }
    }

  expect Output {
    address: Address { payment_credential, .. },
    value: params_value,
    datum: InlineDatum(raw_actual_params),
    ..
  } = outputs |> unsafe.list_at(oidx)
  expect types.ParamsWrapper(actual_params) =
    utils.to_monodatum(raw_actual_params)
  let valid_output_value =
    value.without_lovelace(params_value) == value.without_lovelace(
      param_inp_value,
    )

  and {
    // Gov lock token is burned with no other mints at the synthetics script
    utils.only_mints_this(
      minted,
      mint_script_hash,
      types.gov_lock_token_name,
      -1,
    )?,
    // Gov input contains lock token
    utils.gov_has_lock_token(gov_inp, mint_script_hash)?,
    // Spending valid params
    (value.quantity_of(param_inp_value, mint_script_hash, expected_lock_token) == 1)?,
    valid_output_value?,
    (expected_params == actual_params)?,
    // Sending to this script
    (payment_credential == ScriptCredential(state_script_hash))?,
  }
}

pub fn params_void(
  mint: MintedValue,
  inputs: List<Input>,
  redeemers: Pairs<ScriptPurpose, Redeemer>,
  outputs: List<Output>,
  mint_script_hash: types.ScriptHash,
  price_feed_script_hash: ByteArray,
  spend_script_hash: types.ScriptHash,
  validity_range: ValidityRange,
) {
  expect [Input { output: spent_out, .. }] = {
    let inp <- list.filter(inputs)
    inp.output.address.payment_credential == ScriptCredential(spend_script_hash)
  }

  let params_synthetic = {
    let Output { value: inp_value, datum: inp_datum, .. } = spent_out
    expect [(policy, name, amount)] =
      value.flatten(inp_value |> value.without_lovelace())
    expect InlineDatum(params_data) = inp_datum
    expect types.ParamsWrapper(types.LiveParams { .. }) =
      utils.to_monodatum(params_data)
    expect and {
        policy == mint_script_hash,
        bytearray.take(name, types.params_prefix_length) == types.params_prefix,
        amount == 1,
      }
    bytearray.drop(name, types.params_prefix_length)
  }
  let price_feed_redeemer_raw =
    unsafe.unsome(
      pairs.get_first(
        redeemers,
        WithdrawFrom(utils.stake_cred_from_hash(price_feed_script_hash)),
      ),
    )
  expect [
    types.Feed {
      data: types.PriceFeed {
        synthetic: pf_synthetic,
        denominator,
        validity: pf_validity,
        ..
      },
      ..
    },
  ] = utils.to_pricefeedredeemer(price_feed_redeemer_raw)

  // Tx validity range is a subset of the price feed's validity range
  expect utils.check_price_feed_validity(pf_validity, validity_range)

  expect Output {
    address: new_params_addr,
    value: new_params_value,
    datum: InlineDatum(raw_new_params),
    reference_script,
  } = builtin.head_list(outputs)
  expect types.ParamsWrapper(new_params) = utils.to_monodatum(raw_new_params)
  let valid_output_value =
    value.without_lovelace(new_params_value) == value.without_lovelace(
      spent_out.value,
    )

  let expected_lock_token =
    bytearray.concat(types.params_prefix, params_synthetic)

  and {
    denominator == 0,
    (new_params_addr == spent_out.address)?,
    valid_output_value?,
    reference_script == None,
    new_params == types.VoidedParams,
    (params_synthetic == pf_synthetic)?,
    (value.quantity_of(spent_out.value, mint_script_hash, expected_lock_token) == 1)?,
    utils.mints_nothing_here(value.from_minted_value(mint), mint_script_hash)?,
  }
}
