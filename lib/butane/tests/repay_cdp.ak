use aiken/dict
use aiken/transaction.{
  InlineDatum, Input, Output, OutputReference, TransactionId,
}
use aiken/transaction/credential.{Address, ScriptCredential}
use aiken/transaction/value
use butane/subvalidators/cdp_script.{spend_transitions}
use butane/tests/utils.{
  fake_asset_class, fake_leftovers_hash, fake_mint_hash, fake_state_hash,
}
use butane/types

test spend_0() {
  spend_transitions(
    [],
    [],
    fake_state_hash,
    fake_mint_hash,
    fake_leftovers_hash,
    10_000,
    1000,
    [],
    [],
    fake_asset_class(),
    fn() { True },
    [],
    [],
    [],
    dict.new(),
    0,
    value.zero(),
    0,
    fn(_a, _b, _c, _d, _e) { 0 },
  ) == 0
}

test spend_1() {
  let cdp_datum =
    types.CDP {
      owner: types.AuthorizeWithPubKey("", ""),
      synthetic_asset: "USD",
      synthetic_amount: 20000000,
      start_time: 1000,
    }
  let cdp_datum: Data = cdp_datum
  let cdp_input =
    Input {
      output: Output {
        value: value.add(value.from_lovelace(10000000), fake_state_hash, "", 1),
        address: Address(ScriptCredential(fake_state_hash), None),
        datum: InlineDatum(cdp_datum),
        reference_script: None,
      },
      output_reference: OutputReference {
        transaction_id: TransactionId(""),
        output_index: 0,
      },
    }

  let
    _remaining_outputs,
    x_mint,
    x_btn_delta,
    x_fee,
    x_lock_mints,
  <-
    spend_transitions(
      [cdp_input],
      [],
      fake_state_hash,
      fake_mint_hash,
      fake_leftovers_hash,
      1000,
      100,
      [""],
      [],
      fake_asset_class(),
      fn() { True },
      [utils.usd_params()],
      [utils.usd_price()],
      [
        types.SpendAction {
          spend_type: types.RepayCDP(
            types.AuthorizingDirectly(types.AuthorizedWithExtraSigs),
          ),
          params_idx: 0,
          fee_type: types.FeeInSynthetic,
        },
      ],
      dict.new(),
      0,
      value.zero(),
      0,
    )
  and {
    x_mint == dict.insert(dict.new(), #"555344", -20000000),
    x_btn_delta == 0,
    x_fee == value.zero(),
    x_lock_mints == -1,
  }
}
