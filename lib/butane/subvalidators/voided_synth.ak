use aiken/interval.{Finite, Interval, IntervalBound}
use aiken/list
use aiken/transaction.{InlineDatum, Input, Output}
use aiken/transaction/credential.{Address, ScriptCredential}
use aiken/transaction/value
use butane/types.{CDPCredentialVerifier}
use butane/utils

pub fn collect_voided_cdp(
  verifier: CDPCredentialVerifier,
  mint,
  extra_signatories,
  inputs,
  withdrawals,
  validity_range,
  reference_inputs,
  mint_script_hash,
  state_script_hash,
) {
  expect [types.ParamsData { params, synthetic }] =
    utils.params_from_refs(reference_inputs, mint_script_hash)

  let state_cred = ScriptCredential(state_script_hash)

  expect [(cdp_owner, cdp_oref)] = {
    let acc, inp <- list.reduce(inputs, [])
    let Input {
      output: Output {
        address: Address { payment_credential: inp_cred, .. },
        datum,
        ..
      },
      ..
    } = inp
    if inp_cred == state_cred {
      expect InlineDatum(this_raw_datum) = datum
      expect types.CDP { synthetic_asset: cdp_synthetic_name, owner, .. } =
        utils.to_monodatum(this_raw_datum)
      expect cdp_synthetic_name == synthetic
      [(owner, inp.output_reference), ..acc]
    } else {
      acc
    }
  }

  expect Interval {
    lower_bound: IntervalBound { bound_type: Finite(valid_from), .. },
    upper_bound: IntervalBound { bound_type: Finite(valid_to), .. },
  } = validity_range

  and {
    utils.authorization_check(
      fcredential: cdp_owner,
      this_oref: cdp_oref,
      verifier: verifier,
      extra_signatories: extra_signatories,
      inputs: inputs,
      withdrawals: withdrawals,
      valid_from: valid_from,
      valid_to: valid_to,
    )?,
    (params == types.VoidedParams)?,
    utils.only_mints_this(
      value.from_minted_value(mint),
      mint_script_hash,
      types.cdp_lock_token_name,
      -1,
    ),
  }
}
