use aiken/dict
use aiken/list
use aiken/transaction.{InlineDatum, Input, Output}
use aiken/transaction/credential.{ScriptCredential}
use aiken/transaction/value
use butane/types
use butane/unsafe
use butane/utils

pub fn compat_locking(
  inputs,
  reference_inputs,
  outputs,
  mint,
  state_script_hash: types.ScriptHash,
  mint_script_hash: types.ScriptHash,
  redeemer: types.CompatRedeemer,
) -> Bool {
  expect Input {
    output: Output { datum: InlineDatum(raw_gov_datum), value: gov_value, .. },
    ..
  } =
    unsafe.unsome(
      utils.find_input_with_credential(
        reference_inputs,
        ScriptCredential(state_script_hash),
      ),
    )
  expect types.GovDatum{gov: types.GovNewCompat { upgrade_policy }} =
    utils.to_monodatum(raw_gov_datum)

  when redeemer is {
    types.CompatLock { oidx } -> {
      let Output { value, datum, address, .. } = unsafe.list_at(outputs, oidx)
      expect [Pair(mint_token_name, mint_qty)] =
        mint
          |> value.from_minted_value
          |> value.tokens(mint_script_hash)
          |> dict.to_pairs
      and {
        // Datum is correct
        (datum == InlineDatum(types.CompatLockedTokens))?,
        // Address is correct
        (address.payment_credential == ScriptCredential(state_script_hash))?,
        // Value is correct
        ( value |> value.without_lovelace() ) == value.from_asset(
          upgrade_policy,
          mint_token_name,
          mint_qty,
        ),
        // Not spending anything at the state script address
        (utils.find_input_with_credential(
          inputs,
          ScriptCredential(state_script_hash),
        ) == None)?,
        // Gov input has lock token
        (value.quantity_of(
          gov_value,
          mint_script_hash,
          types.gov_lock_token_name,
        ) > 0)?,
      }
    }
    types.CompatUnlock { soidx } -> {
      expect [_, Pair(releasing_policy, releasing_tupl)] =
        list.foldr(
          inputs,
          value.zero(),
          fn(i: Input, v) {
            if
            i.output.address.payment_credential == ScriptCredential(
              state_script_hash,
            ){
            
              expect InlineDatum(raw_datum) = i.output.datum
              expect utils.to_monodatum(raw_datum) == types.CompatLockedTokens
              value.merge(v, i.output.value)
            } else {
              v
            }
          },
        )
          |> value.to_dict
          |> dict.to_pairs

      expect [Pair(releasing_token_name, releasing_amount)] =
        releasing_tupl |> dict.to_pairs
      expect [Pair(mint_token_name, mint_qty)] =
        mint
          |> value.from_minted_value
          |> value.tokens(mint_script_hash)
          |> dict.to_pairs
      and {
        (releasing_policy == upgrade_policy)?,
        (mint_token_name == releasing_token_name)?,
        // Gov input has lock token
        (value.quantity_of(
          gov_value,
          mint_script_hash,
          types.gov_lock_token_name,
        ) > 0)?,
        // Handle change
        when soidx is {
          Some(oidx) -> {
            expect Output {
              value,
              address,
              datum: InlineDatum(change_datum),
              ..
            } = unsafe.list_at(outputs, oidx)
            expect types.CompatLockedTokens = utils.to_monodatum(change_datum)
            and {
              ( value |> value.without_lovelace() ) == value.from_asset(
                upgrade_policy,
                releasing_token_name,
                releasing_amount + mint_qty,
              ),
              (address.payment_credential == ScriptCredential(state_script_hash))?,
            }
          }
          None -> (releasing_amount == -mint_qty)?
        },
      }
    }
  }
}
