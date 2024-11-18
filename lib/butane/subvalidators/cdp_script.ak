use aiken/builtin
use aiken/dict.{Dict}
use aiken/hash.{Blake2b_224, Hash}
use aiken/interval.{Finite, Interval, IntervalBound}
use aiken/list
use aiken/math/rational
use aiken/pairs
use aiken/transaction.{
  InlineDatum, Input, Output, Redeemer, ScriptPurpose, ValidityRange,
  WithdrawFrom,
}
use aiken/transaction/credential.{
  Address, Inline, ScriptCredential, StakeCredential, VerificationKey,
  VerificationKeyCredential,
}
use aiken/transaction/value.{AssetName, MintedValue, Value}
use butane/prices
use butane/types
use butane/unsafe
use butane/utils

pub fn spend_transitions(
  inputs: List<Input>,
  outputs: List<Output>,
  state_script_hash: types.ScriptHash,
  mint_script_hash: types.ScriptHash,
  leftovers_script_hash: types.ScriptHash,
  valid_to: Int,
  valid_from: Int,
  extra_signatories: List<Hash<Blake2b_224, VerificationKey>>,
  withdrawals: Pairs<StakeCredential, Int>,
  fee_token: types.AssetClass,
  redemption_authorized: fn() -> Bool,
  param_list: List<types.ParamsData>,
  price_feeds_list: List<types.PriceFeed>,
  spends: List<types.SpendAction>,
  x_mint: Dict<AssetName, Int>,
  x_btn_delta: Int,
  x_fee: Value,
  x_lock_mints: Int,
  callback: fn(List<Output>, Dict<AssetName, Int>, Int, Value, Int) -> a,
) {
  when spends is {
    [] -> {
      // Not spending anything else from the state script without validation
      expect
        {
          let i <- list.all(inputs)
          i.output.address.payment_credential != ScriptCredential(
            state_script_hash,
          )
        }?
      // Validating outputs
      callback(outputs, x_mint, x_btn_delta, x_fee, x_lock_mints)
    }
    [
      types.SpendAction { spend_type: this_action, params_idx, fee_type },
      ..remaining_actions
    ] -> {
      let pass_in =
        fn(remaining_inputs, remaining_outputs, d_lock_mints: Int) {
          fn(y_mint: Dict<AssetName, Int>, y_btn_delta: Int, y_fee: Value) {
            spend_transitions(
              remaining_inputs,
              remaining_outputs,
              state_script_hash,
              mint_script_hash,
              leftovers_script_hash,
              valid_to,
              valid_from,
              extra_signatories,
              withdrawals,
              fee_token,
              redemption_authorized,
              param_list,
              price_feeds_list,
              remaining_actions,
              dict.union_with(
                x_mint,
                y_mint,
                fn(_, q0, q1) {
                  let q = q0 + q1
                  if q == 0 {
                    None
                  } else {
                    Some(q)
                  }
                },
              ),
              x_btn_delta + y_btn_delta,
              value.merge(y_fee, x_fee),
              x_lock_mints + d_lock_mints,
              callback,
            )
          }
        }
      expect [
        Input {
          output: Output { datum: input_datum, value: cdp_value, .. },
          output_reference: this_oref,
        },
        ..remaining_inputs
      ] = utils.until_input_from(ScriptCredential(state_script_hash), inputs)
      expect InlineDatum(data) = input_datum
      expect types.CDP {
        owner,
        synthetic_asset: cdp_synthetic_name,
        synthetic_amount: cdp_synthetic_amount,
        start_time: cdp_start_time,
      } = utils.to_monodatum(data)
      expect types.ParamsData {
        params: types.LiveParams{params: types.ActiveParams {
          collateral_assets: cdp_assets,
          weights: cdp_weights,
          denominator: cdp_denominator,
          max_liquidation_return: cdp_max_liquidation_return,
          max_proportions: cdp_max_proportions,
          treasury_liquidation_share: cdp_treasury_liquidation_share,
          minimum_outstanding_synthetic: cdp_min_outstanding,
          redemption_share: cdp_redemption_share,
          interest_rates: cdp_interest_rates,
          fee_token_discount,
          staking_interest_rates,
        }},
        synthetic: synthetic_name,
      } = unsafe.list_at(param_list, params_idx)
      let types.PriceFeed {
        collateral_prices: p_list,
        denominator: p_denom,
        ..
      } = unsafe.list_at(price_feeds_list, params_idx)

      expect (cdp_synthetic_name == synthetic_name)?

      let cdp_value_no_lock =
        cdp_value |> value.add(mint_script_hash, types.cdp_lock_token_name, -1)
      let fee_percent =
        utils.calculate_fee_percent(
          cdp_interest_rates,
          cdp_start_time,
          valid_to,
        )

      let fee_in_synthetic =
        fee_percent * cdp_synthetic_amount / types.bp_precision / types.milliseconds_in_year

      when this_action is {
        types.RepayCDP(verifier) -> {
          // Authorized by owner
          expect
            utils.authorization_check(
              fcredential: owner,
              this_oref: this_oref,
              verifier: verifier,
              extra_signatories: extra_signatories,
              inputs: inputs,
              withdrawals: withdrawals,
              valid_from: valid_from,
              valid_to: valid_to,
            )?
          utils.get_state_delta(
            synthetic_name: synthetic_name,
            repaid_amount: cdp_synthetic_amount,
            fee_type: fee_type,
            fee_in_synthetic: fee_in_synthetic,
            staking_interest_rates: staking_interest_rates,
            cdp_start_time: cdp_start_time,
            cdp_close_time: valid_to,
            fee_token_discount: fee_token_discount,
            treasury_share: value.zero(),
            p_list: p_list,
            p_denom: p_denom,
            collateral_assets: cdp_assets,
            fee_token: fee_token,
            g: pass_in(remaining_inputs, outputs, -1),
          )
        }
        types.LiquidateCDP -> {
          // Full liquidation, no leftovers
          let max_liquidation_return_rat =
            unsafe.unsome(
              rational.new(cdp_max_liquidation_return, types.bp_precision),
            )
          let cr, hf <-
            prices.get_collateral_finances(
              p_list: p_list,
              p_dom: p_denom,
              v: cdp_value_no_lock,
              assets: cdp_assets,
              w_list: cdp_weights,
              w_dom: cdp_denominator,
              max_proportions_list: cdp_max_proportions,
              synth_amount: cdp_synthetic_amount + fee_in_synthetic,
              callback: _,
            )
          expect and {
              // Must be unhealthy
              (rational.compare(hf, rational.from_int(1)) == Less)?,
              // Must not be earning more than max liquidation return
              (rational.compare(cr, max_liquidation_return_rat) != Greater)?,
            }
          let treasury_share =
            utils.get_treasury_share(
              cdp_value,
              cdp_treasury_liquidation_share,
              cr,
            )

          utils.get_state_delta(
            synthetic_name: synthetic_name,
            repaid_amount: cdp_synthetic_amount,
            fee_type: fee_type,
            fee_in_synthetic: fee_in_synthetic,
            staking_interest_rates: staking_interest_rates,
            cdp_start_time: cdp_start_time,
            cdp_close_time: valid_to,
            fee_token_discount: fee_token_discount,
            treasury_share: treasury_share,
            p_list: p_list,
            p_denom: p_denom,
            collateral_assets: cdp_assets,
            fee_token: fee_token,
            g: pass_in(remaining_inputs, outputs, -1),
          )
        }
        types.PartialLiquidateCDP { repay_amount } -> {
          let max_liquidation_return_rat =
            unsafe.unsome(
              rational.new(cdp_max_liquidation_return, types.bp_precision),
            )
          let _cr, hf <-
            prices.get_collateral_finances(
              p_list: p_list,
              p_dom: p_denom,
              v: cdp_value_no_lock,
              assets: cdp_assets,
              w_list: cdp_weights,
              w_dom: cdp_denominator,
              max_proportions_list: cdp_max_proportions,
              synth_amount: cdp_synthetic_amount + fee_in_synthetic,
              callback: _,
            )
          // If there's leftover collateral for the borrower to reclaim, there should be a new output
          expect Output {
            address: Address {
              payment_credential: ScriptCredential(leftover_output_script_hash),
              ..
            },
            datum: InlineDatum(leftover_datum_data),
            value: leftover_value,
            ..
          } = builtin.head_list(outputs)

          let claimed_value_no_lock =
            value.merge(cdp_value, value.negate(leftover_value))

          let claimed_value_cr, _ <-
            prices.get_collateral_finances(
              p_list: p_list,
              p_dom: p_denom,
              v: claimed_value_no_lock,
              assets: cdp_assets,
              w_list: cdp_weights,
              w_dom: cdp_denominator,
              max_proportions_list: cdp_max_proportions,
              synth_amount: repay_amount,
              callback: _,
            )

          // Claiming at most the max_liquidation_return
          let claimed_value_comp =
            rational.compare(claimed_value_cr, max_liquidation_return_rat)
          expect claimed_value_comp != Greater

          expect leftover_output_script_hash == state_script_hash
          // If creating a new CDP from the leftovers (partial liquidation)
          expect types.CDP {
            synthetic_amount: leftover_synthetic_amount,
            start_time: leftover_start_time,
            owner: leftover_owner,
            synthetic_asset: leftover_synthetic_name,
          } = utils.to_monodatum(leftover_datum_data)

          // New CDP still has lock token
          expect
            value.quantity_of(
              leftover_value,
              mint_script_hash,
              types.cdp_lock_token_name,
            ) == 1

          let leftover_fee_in_synthetic =
            fee_percent * leftover_synthetic_amount / types.bp_precision / types.milliseconds_in_year
          let _, new_hf <-
            prices.get_collateral_finances(
              p_list: p_list,
              p_dom: p_denom,
              v: leftover_value
                |> value.add(mint_script_hash, types.cdp_lock_token_name, -1),
              assets: cdp_assets,
              w_list: cdp_weights,
              w_dom: cdp_denominator,
              max_proportions_list: cdp_max_proportions,
              synth_amount: leftover_synthetic_amount + leftover_fee_in_synthetic,
              callback: _,
            )
          let actual_repayed_amount =
            cdp_synthetic_amount - leftover_synthetic_amount
          let proportional_fee_in_synthetic =
            fee_percent * actual_repayed_amount / types.bp_precision / types.milliseconds_in_year
          expect and {
              // CDP must be unhealthy
              (rational.compare(hf, rational.from_int(1)) == Less)?,
              // Liquidation must be partial
              repay_amount < cdp_synthetic_amount,
              leftover_synthetic_amount >= cdp_min_outstanding,
              // Haven't changed any constants in the datum
              leftover_synthetic_name == synthetic_name,
              leftover_owner == owner,
              leftover_start_time == cdp_start_time,
              // Repayed the right amount
              actual_repayed_amount == repay_amount,
              // New CDP is healthy
              (rational.compare(new_hf, rational.from_int(1)) != Less)?,
              // Not adding any additional tokens to the leftover value
              {
                let
                  pol,
                  tok,
                  qty,
                  acc,
                <-
                  value.reduce(
                    leftover_value
                      |> value.add(mint_script_hash, types.cdp_lock_token_name, -1),
                    True,
                  )
                acc && value.quantity_of(cdp_value_no_lock, pol, tok) >= qty
              },
            }

          let treasury_share =
            utils.get_treasury_share(
              claimed_value_no_lock,
              cdp_treasury_liquidation_share,
              claimed_value_cr,
            )

          utils.get_state_delta(
            synthetic_name: synthetic_name,
            repaid_amount: repay_amount,
            fee_type: fee_type,
            fee_in_synthetic: proportional_fee_in_synthetic,
            staking_interest_rates: staking_interest_rates,
            cdp_start_time: cdp_start_time,
            cdp_close_time: valid_to,
            fee_token_discount: fee_token_discount,
            treasury_share: treasury_share,
            p_list: p_list,
            p_denom: p_denom,
            collateral_assets: cdp_assets,
            fee_token: fee_token,
            g: pass_in(remaining_inputs, builtin.tail_list(outputs), 0),
          )
        }
        types.LeftoversLiquidateCDP -> {
          let max_liquidation_return_rat =
            unsafe.unsome(
              rational.new(cdp_max_liquidation_return, types.bp_precision),
            )
          let cr, hf <-
            prices.get_collateral_finances(
              p_list: p_list,
              p_dom: p_denom,
              v: cdp_value_no_lock,
              assets: cdp_assets,
              w_list: cdp_weights,
              w_dom: cdp_denominator,
              max_proportions_list: cdp_max_proportions,
              synth_amount: cdp_synthetic_amount + fee_in_synthetic,
              callback: _,
            )
          // If there's leftover collateral for the borrower to reclaim, there should be a new output
          expect Output {
            address: Address {
              payment_credential: ScriptCredential(leftover_output_script_hash),
              ..
            },
            datum: InlineDatum(leftover_datum_data),
            value: leftover_value,
            ..
          } = builtin.head_list(outputs)

          let claimed_value =
            value.merge(cdp_value, value.negate(leftover_value))
          // Account for case where leftover burns lock token
          let claimed_value_no_lock =
            claimed_value
              |> value.add(mint_script_hash, types.cdp_lock_token_name, -1)

          let claimed_value_cr, _ <-
            prices.get_collateral_finances(
              p_list: p_list,
              p_dom: p_denom,
              v: claimed_value_no_lock,
              assets: cdp_assets,
              w_list: cdp_weights,
              w_dom: cdp_denominator,
              max_proportions_list: cdp_max_proportions,
              synth_amount: cdp_synthetic_amount,
              callback: _,
            )

          let treasury_share =
            utils.get_treasury_share(
              claimed_value_no_lock,
              cdp_treasury_liquidation_share,
              claimed_value_cr,
            )
          // If fully liquidated but there's still leftovers
          expect types.LeftoversDatum { owner: leftover_owner }: types.LeftoversDatum =
            leftover_datum_data
          expect and {
              // Collections script datum must be owned by CDP owner
              (leftover_owner == owner)?,
              (leftover_output_script_hash == leftovers_script_hash)?,
              // Claiming at most the max_liquidation_return
              (rational.compare(claimed_value_cr, max_liquidation_return_rat) != Greater)?,
              // Must be unhealthy
              (rational.compare(hf, rational.from_int(1)) == Less)?,
              // We must be exceeding the maximum allowed earnings, forcing a leftover
              (rational.compare(cr, max_liquidation_return_rat) == Greater)?,
              // Can't add any additional tokens to the leftover
              {
                let pol, tok, qty, acc <- value.reduce(leftover_value, True)
                acc && value.quantity_of(cdp_value_no_lock, pol, tok) >= qty
              },
            }

          utils.get_state_delta(
            synthetic_name: synthetic_name,
            repaid_amount: cdp_synthetic_amount,
            fee_type: fee_type,
            fee_in_synthetic: fee_in_synthetic,
            staking_interest_rates: staking_interest_rates,
            cdp_start_time: cdp_start_time,
            cdp_close_time: valid_to,
            fee_token_discount: fee_token_discount,
            treasury_share: treasury_share,
            p_list: p_list,
            p_denom: p_denom,
            collateral_assets: cdp_assets,
            fee_token: fee_token,
            g: pass_in(remaining_inputs, builtin.tail_list(outputs), -1),
          )
        }
        types.RedeemCDP -> {
          expect redemption_authorized()
          let repaying = cdp_synthetic_amount + fee_in_synthetic
          let redeeming_value =
            repaying * cdp_redemption_share / types.bp_precision
          let collateral_value, _ <-
            prices.get_collateral_finances(
              p_list: p_list,
              p_dom: p_denom,
              v: cdp_value_no_lock,
              assets: cdp_assets,
              w_list: cdp_weights,
              w_dom: cdp_denominator,
              max_proportions_list: cdp_max_proportions,
              synth_amount: 1,
              callback: _,
            )
          let collateral_value =
            collateral_value
              |> rational.truncate
          expect [
            Output {
              value: leftover_value,
              address: Address {
                payment_credential: ScriptCredential(
                  leftover_output_script_hash,
                ),
                ..
              },
              datum: InlineDatum(leftover_datum_data),
              ..
            },
            ..remaining_outputs
          ] = outputs
          expect types.LeftoversDatum { owner: leftover_owner }: types.LeftoversDatum =
            leftover_datum_data
          expect leftover_owner == owner
          let leftover_collateral_value, _ <-
            prices.get_collateral_finances(
              p_list: p_list,
              p_dom: p_denom,
              v: leftover_value,
              assets: cdp_assets,
              w_list: cdp_weights,
              w_dom: cdp_denominator,
              max_proportions_list: cdp_max_proportions,
              synth_amount: 1,
              callback: _,
            )
          let leftover_collateral_value =
            leftover_collateral_value |> rational.truncate
          expect fee_type == types.FeeInSynthetic
          expect leftover_collateral_value >= collateral_value - redeeming_value
          // leftover_value's entries must be smaller than or equal to cdp_value_no_lock's corresponding entries (can't add any additional tokens)
          expect {
            let pol, tok, qty, acc <- value.reduce(leftover_value, True)
            acc && value.quantity_of(cdp_value_no_lock, pol, tok) >= qty
          }
          expect leftover_output_script_hash == leftovers_script_hash
          utils.get_state_delta(
            synthetic_name: synthetic_name,
            repaid_amount: cdp_synthetic_amount,
            fee_type: types.FeeInSynthetic,
            fee_in_synthetic: fee_in_synthetic,
            staking_interest_rates: [],
            cdp_start_time: cdp_start_time,
            cdp_close_time: 0,
            fee_token_discount: 0,
            treasury_share: value.zero(),
            p_list: p_list,
            p_denom: p_denom,
            collateral_assets: cdp_assets,
            fee_token: fee_token,
            g: pass_in(remaining_inputs, remaining_outputs, -1),
          )
        }
      }
    }
  }
}

pub fn create_transitions(
  mint_script_hash: types.ScriptHash,
  state_script_hash: types.ScriptHash,
  valid_from: Int,
  valid_to: Int,
  param_list: List<types.ParamsData>,
  price_feeds_list: List<types.PriceFeed>,
  actions: List<Int>,
  outputs: List<Output>,
  x_mint: Dict<AssetName, Int>,
  x_btn_delta: Int,
  x_fee: Value,
  x_lock_mints: Int,
) {
  when actions is {
    [] | [0] ->
      (
        types.StateDelta {
          mint: x_mint,
          btn_delta: x_btn_delta,
          fee: x_fee,
          lock_mints: x_lock_mints,
        },
        builtin.head_list(outputs),
      )
    [num_create, ..xsactions] -> {
      expect [
        types.ParamsData {
          params: types.LiveParams{params: types.ActiveParams {
            weights: cdp_weights,
            collateral_assets: cdp_collateral,
            denominator: cdp_denominator,
            minimum_outstanding_synthetic: cdp_min_outstanding,
            max_proportions: cdp_max_proportions,
            ..
          }},
          synthetic: expected_synthetic_name,
        },
        ..xs_params
      ] = param_list
      expect [
        types.PriceFeed {
          collateral_prices: cdp_price_list,
          denominator: cdp_price_denom,
          ..
        },
        ..xs_prices
      ] = price_feeds_list
      let (synthetics_minted, other_outputs) =
        utils.until_zero(
          num_create,
          fn(a: Int, b: List<Output>) { (a, b) },
          fn(acc: fn(Int, List<Output>) -> (Int, List<Output>)) {
            fn(curr_minted: Int, curr_outputs: List<Output>) -> (
              Int,
              List<Output>,
            ) {
              when curr_outputs is {
                [new_output, ..other_outputs] -> {
                  expect Output {
                    datum: InlineDatum(out_data),
                    address: out_address,
                    value: new_cdp_value,
                    ..
                  } = new_output

                  expect types.CDP {
                    synthetic_asset: synthetic_name,
                    synthetic_amount: new_synthetic_amount,
                    start_time,
                    ..
                  } = utils.to_monodatum(out_data)

                  let _, hf <-
                    prices.get_collateral_finances(
                      p_list: cdp_price_list,
                      p_dom: cdp_price_denom,
                      v: new_cdp_value
                        |> value.add(
                            mint_script_hash,
                            types.cdp_lock_token_name,
                            -1,
                          ),
                      assets: cdp_collateral,
                      w_list: cdp_weights,
                      w_dom: cdp_denominator,
                      max_proportions_list: cdp_max_proportions,
                      synth_amount: new_synthetic_amount,
                      callback: _,
                    )
                  expect and {
                      // CDP is healthy
                      (rational.compare(hf, rational.from_int(1)) != Less)?,
                      // At script's address
                      (out_address.payment_credential == ScriptCredential(
                        state_script_hash,
                      ))?,
                      // CDP start time is the lower bound of the validity range
                      (start_time > 0 && start_time == valid_from)?,
                      // CDP has lock token
                      (value.quantity_of(
                        new_cdp_value,
                        mint_script_hash,
                        types.cdp_lock_token_name,
                      ) == 1)?,
                      // CDP is using the right params
                      (expected_synthetic_name == synthetic_name)?,
                      // CDP has enough outstanding synthetic
                      (new_synthetic_amount >= cdp_min_outstanding)?,
                    }
                  acc(curr_minted + new_synthetic_amount, other_outputs)
                }
                _ -> fail
              }
            }
          },
        )(
          0,
          outputs,
        )
      create_transitions(
        mint_script_hash,
        state_script_hash,
        valid_from,
        valid_to,
        xs_params,
        xs_prices,
        xsactions,
        other_outputs,
        x_mint
          |> dict.insert_with(
              expected_synthetic_name,
              synthetics_minted,
              fn(_k, a, b) {
                let c = a + b
                if c == 0 {
                  None
                } else {
                  Some(c)
                }
              },
            ),
        x_btn_delta,
        x_fee,
        x_lock_mints + num_create,
      )
    }
  }
}

pub fn cdp_script(
  mint: MintedValue,
  outputs: List<Output>,
  redeemers: Pairs<ScriptPurpose, Redeemer>,
  inputs: List<Input>,
  reference_inputs: List<Input>,
  extra_signatories: List<Hash<Blake2b_224, VerificationKey>>,
  validity_range: ValidityRange,
  withdrawals: Pairs<StakeCredential, Int>,
  mint_script_hash: types.ScriptHash,
  state_script_hash: types.ScriptHash,
  spends: List<types.SpendAction>,
  extra: List<Int>,
  price_feed_script_hash: types.ScriptHash,
  leftovers_script_hash: types.ScriptHash,
  fee_token: types.AssetClass,
  redemption_nft: types.AssetClass,
) -> Bool {
  let redemption_authorized =
    fn() {
      let types.AssetClass {
        policy_id: redemption_pid,
        asset_name: redemption_an,
      } = redemption_nft
      let Input {
        output: Output {
          address: Address { payment_credential: redemption_nft_credential, .. },
          ..
        },
        ..
      } =
        unsafe.unsome(
          list.find(
            reference_inputs,
            fn(r: Input) {
              value.quantity_of(r.output.value, redemption_pid, redemption_an) == 1
            },
          ),
        )
      when redemption_nft_credential is {
        VerificationKeyCredential(key_hash) ->
          list.has(extra_signatories, key_hash)
        script_cred -> utils.withdraws_zero(withdrawals, Inline(script_cred))
      }
    }
  expect Interval {
    lower_bound: IntervalBound { bound_type: Finite(valid_from), .. },
    upper_bound: IntervalBound { bound_type: Finite(valid_to), .. },
  } = validity_range
  let param_list = utils.params_from_refs(reference_inputs, mint_script_hash)
  let price_feed_redeemer_raw =
    unsafe.unsome(
      pairs.get_first(
        redeemers,
        WithdrawFrom(utils.stake_cred_from_hash(price_feed_script_hash)),
      ),
    )
  let price_feed_redeemer = utils.to_pricefeedredeemer(price_feed_redeemer_raw)
  let price_feeds_list: List<types.PriceFeed> = {
    let
      types.Feed { data: p_data, .. },
      types.ParamsData { synthetic: params_synth, .. },
    <- list.map2(price_feed_redeemer, param_list)
    expect and {
        // All price feeds are valid for this transaction
        utils.check_price_feed_validity(p_data.validity, validity_range)?,
        // All price feeds are for the correct synthetic
        (p_data.synthetic == params_synth)?,
      }
    p_data
  }
  let remaining_outputs, x_mint, x_btn_delta, x_fee, x_lock_mints <-
    spend_transitions(
      inputs: inputs,
      outputs: outputs,
      state_script_hash: state_script_hash,
      mint_script_hash: mint_script_hash,
      leftovers_script_hash: leftovers_script_hash,
      valid_to: valid_to,
      valid_from: valid_from,
      extra_signatories: extra_signatories,
      withdrawals: withdrawals,
      fee_token: fee_token,
      redemption_authorized: redemption_authorized,
      param_list: param_list,
      price_feeds_list: price_feeds_list,
      spends: spends,
      x_mint: dict.new(),
      x_btn_delta: 0,
      x_fee: value.zero(),
      x_lock_mints: 0,
      callback: _,
    )
  let (
    types.StateDelta {
      mint: state_mint,
      btn_delta: state_btn_delta,
      fee: state_fee,
      lock_mints: state_lock_mints,
    },
    maybe_fee_output,
  ) =
    create_transitions(
      mint_script_hash: mint_script_hash,
      state_script_hash: state_script_hash,
      valid_from: valid_from,
      valid_to: valid_to,
      param_list: param_list,
      price_feeds_list: price_feeds_list,
      actions: extra,
      outputs: remaining_outputs,
      x_mint: x_mint,
      x_btn_delta: x_btn_delta,
      x_fee: x_fee,
      x_lock_mints: x_lock_mints,
    )
  let valid_fee_output = or {
      state_fee == value.zero(),
      {
        let expected_fee_address =
          Address {
            payment_credential: ScriptCredential(state_script_hash),
            stake_credential: Some(Inline(ScriptCredential(mint_script_hash))),
          }
        let Output {
          value: actual_fee_utxo_value,
          address: actual_fee_utxo_address,
          datum: actual_fee_utxo_datum,
          ..
        } = maybe_fee_output
        and {
          // Sending at least the correct fee
          {
            let pol, tok, qty, acc <- value.reduce(actual_fee_utxo_value, True)
            (acc && value.quantity_of(state_fee, pol, tok) <= qty)?
          },
          // At the correct address
          (actual_fee_utxo_address == expected_fee_address)?,
          // With the correct datum
          (actual_fee_utxo_datum == InlineDatum(
            types.TreasuryDatum { treas: types.TreasuryFromFees },
          ))?,
        }
      },
    }
  let types.AssetClass { policy_id: fee_token_pid, asset_name: fee_token_name } =
    fee_token
  let minted_value = value.from_minted_value(mint)
  let state_mint_after_insertion =
    if state_lock_mints == 0 {
      state_mint
    } else {
      state_mint
        |> dict.insert(types.cdp_lock_token_name, state_lock_mints)
    }
  and {
    // Mint here is correct
    (state_mint_after_insertion == (
      minted_value |> value.tokens(mint_script_hash)
    ))?,
    // Mint btn is correct
    (( minted_value |> value.quantity_of(fee_token_pid, fee_token_name) ) == state_btn_delta)?,
    // Fees are correct
    valid_fee_output?,
  }
}
