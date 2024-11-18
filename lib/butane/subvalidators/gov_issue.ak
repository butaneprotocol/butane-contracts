use aiken/list
use aiken/pairs
use aiken/transaction.{InlineDatum, Input, Output}
use aiken/transaction/credential.{ScriptCredential}
use aiken/transaction/value.{MintedValue}
use butane/types.{AssetClass}
use butane/unsafe
use butane/utils

pub fn gov_issue(
  inputs: List<Input>,
  outputs: List<Output>,
  mint: MintedValue,
  gov_nft: AssetClass,
  state_hash: ByteArray,
  mint_script_hash: types.ScriptHash,
  output_idx: Int,
) {
  let minted = value.from_minted_value(mint)
  let gov_output = unsafe.list_at(outputs, output_idx)
  // 0 inputs from the state script
  expect [] =
    inputs
      |> list.filter(
          fn(inp) {
            inp.output.address.payment_credential == ScriptCredential(
              state_hash,
            )
          },
        )
  expect InlineDatum(raw_datum) = gov_output.datum
  expect types.GovDatum { .. } = utils.to_monodatum(raw_datum)

  and {
    // Gov NFT is found (authorization)
    list.any(
      inputs,
      fn(input) {
        value.quantity_of(
          input.output.value,
          gov_nft.policy_id,
          gov_nft.asset_name,
        ) > 0
      },
    )?,
    // Correctly mint 1 singular control token
    utils.only_mints_this(
      minted,
      mint_script_hash,
      types.gov_lock_token_name,
      1,
    )?,
    // Output has the correct value
    (value.without_lovelace(gov_output.value) == value.from_asset(
      mint_script_hash,
      types.gov_lock_token_name,
      1,
    ))?,
    // ...and is at the correct address
    (gov_output.address.payment_credential == ScriptCredential(state_hash))?,
  }
}

pub fn consume_external(
  inputs: List<Input>,
  mint,
  withdrawals,
  state_hash: ByteArray,
  mint_script_hash: types.ScriptHash,
) {
  let minted = value.from_minted_value(mint)
  expect [gov_input] =
    inputs
      |> list.filter(
          fn(inp) {
            inp.output.address.payment_credential == ScriptCredential(
              state_hash,
            )
          },
        )
  let gov_output = gov_input.output
  expect InlineDatum(raw_datum) = gov_output.datum
  expect types.GovDatum{gov: types.ExternalScript { other_script, .. }} =
    utils.to_monodatum(raw_datum)
  and {
    utils.only_mints_this(
      minted,
      mint_script_hash,
      types.gov_lock_token_name,
      -1,
    )?,
    (value.without_lovelace(gov_output.value) == value.from_asset(
      mint_script_hash,
      types.gov_lock_token_name,
      1,
    ))?,
    pairs.has_key(withdrawals, utils.stake_cred_from_hash(other_script)),
  }
}
