use aiken/dict
use aiken/interval.{Finite, Interval, IntervalBound}
use aiken/list
use aiken/transaction.{InlineDatum, Input, Output}
use aiken/transaction/credential.{Address, ScriptCredential}
use aiken/transaction/value
use butane/types
use butane/unsafe
use butane/utils

// Staked value has to be locked by a lock token so we can know the authenticity of start time
// Start time always has to be after the start time of the transaction, to prevent setting it in the past,
// which would allow extraction of unearnt interest
pub fn staking_script(
  mint_script_hash,
  spend_script_hash,
  withdrawals,
  inputs,
  outputs,
  reference_inputs,
  mint,
  validity_range,
  extra_signatories,
  staking_redeemer,
) -> Bool {
  let minted = value.from_minted_value(mint)
  let state_cred = ScriptCredential(spend_script_hash)
  expect [types.ParamsData { params, synthetic: params_synth }] =
    utils.params_from_refs(reference_inputs, mint_script_hash)
  expect Interval {
    lower_bound: IntervalBound { bound_type: Finite(valid_from), .. },
    upper_bound: IntervalBound { bound_type: Finite(valid_to), .. },
  } = validity_range
  when staking_redeemer is {
    types.StakeSynthetics { staked_amount } -> {
      expect [] =
        list.filter(
          inputs,
          fn(i: Input) { i.output.address.payment_credential == state_cred },
        )
      expect Output {
        address: Address { payment_credential, .. },
        datum: InlineDatum(raw_staked_datum),
        value: staked_value,
        ..
      } = unsafe.list_at(outputs, 0)
      expect types.StakedSynthetics {
        owner: _owner,
        synthetic_asset,
        start_time,
      } = utils.to_monodatum(raw_staked_datum)
      and {
        payment_credential == state_cred,
        utils.only_mints_this(
          minted,
          mint_script_hash,
          types.staking_lock_token_name,
          1,
        )?,
        (start_time >= valid_to)?,
        ((
          staked_value
            |> value.without_lovelace
        ) == (
          value.from_asset(mint_script_hash, types.staking_lock_token_name, 1)
            |> value.add(mint_script_hash, synthetic_asset, staked_amount)
        ))?,
        (params_synth == synthetic_asset)?,
      }
    }
    types.UnstakeSynthetics { verifier } -> {
      expect [
        Input {
          output: Output {
            datum: InlineDatum(raw_staked_datum),
            value: staked_value,
            ..
          },
          output_reference: this_oref,
        },
      ] =
        list.filter(
          inputs,
          fn(i: Input) { i.output.address.payment_credential == state_cred },
        )
      expect types.StakedSynthetics { owner, synthetic_asset, start_time } =
        utils.to_monodatum(raw_staked_datum)
      let end_time = valid_from
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
      let minted_here = value.tokens(minted, mint_script_hash) |> dict.to_pairs
      let staked_amount =
        value.quantity_of(staked_value, mint_script_hash, synthetic_asset)
      expect types.LiveParams{params: types.ActiveParams {
        staking_interest_rates,
        ..
      }}: types.Params = params
      let earnings_percent =
        utils.calculate_earnings_percent(
          staking_interest_rates,
          start_time,
          end_time,
        )
      let earnings_interest =
        earnings_percent * staked_amount / types.bp_precision / types.milliseconds_in_year
      and {
        or {
          minted_here == [
            Pair(types.staking_lock_token_name, -1),
            Pair(synthetic_asset, earnings_interest),
          ],
          minted_here == [
            Pair(synthetic_asset, earnings_interest),
            Pair(types.staking_lock_token_name, -1),
          ],
        },
        (params_synth == synthetic_asset)?,
        (end_time > start_time)?,
      }
    }
  }
}
