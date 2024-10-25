use aiken/dict
use aiken/fuzz
use aiken/list
use aiken/transaction.{InlineDatum, Output}
use aiken/transaction/credential.{Address, Inline, ScriptCredential}
use aiken/transaction/value
use butane/subvalidators/cdp_script.{create_transitions}
use butane/tests/fuzzers
use butane/tests/utils.{
  change_output, fake_mint_hash, fake_state_hash, usd_params, usd_price,
}
use butane/types

test create_0() {
  create_transitions(
    fake_mint_hash,
    fake_state_hash,
    0,
    0,
    [],
    [],
    [],
    [change_output()],
    dict.new(),
    0,
    value.zero(),
    0,
  ) == (types.StateDelta(dict.new(), 0, value.zero(), 0), change_output())
}

test create_1() {
  let cdp_datum =
    types.CDP {
      owner: types.AuthorizeWithConstraint(
        types.MustWithdrawFrom(Inline(ScriptCredential(fake_state_hash))),
      ),
      synthetic_asset: "USD",
      synthetic_amount: 10,
      start_time: 1000,
    }
  let cdp_datum: Data = cdp_datum
  let cdp_output =
    Output {
      value: value.add(value.from_lovelace(10000000), fake_state_hash, "", 1),
      address: Address(ScriptCredential(fake_state_hash), None),
      datum: InlineDatum(cdp_datum),
      reference_script: None,
    }
  create_transitions(
    fake_mint_hash,
    fake_state_hash,
    1000,
    3000,
    [usd_params()],
    [usd_price()],
    [1],
    [cdp_output, change_output()],
    dict.new(),
    0,
    value.zero(),
    0,
  ) == (
    types.StateDelta(dict.insert(dict.new(), #"555344", 10), 0, value.zero(), 1),
    change_output(),
  )
}

fn push_to_tail(list: List<a>, element: a) -> List<a> {
  when list is {
    [] ->
      [element]
    [head, ..tail] ->
      [head, ..push_to_tail(tail, element)]
  }
}

test create_composition_simple() {
  let cdp_datum =
    types.CDP {
      owner: types.AuthorizeWithConstraint(
        types.MustWithdrawFrom(Inline(ScriptCredential(fake_state_hash))),
      ),
      synthetic_asset: "USD",
      synthetic_amount: 10,
      start_time: 1000,
    }
  let cdp_datum: Data = cdp_datum
  let cdp_outputs =
    [
      Output {
        value: value.add(value.from_lovelace(10000000), fake_state_hash, "", 1),
        address: Address(ScriptCredential(fake_state_hash), None),
        datum: InlineDatum(cdp_datum),
        reference_script: None,
      },
      Output {
        value: value.add(value.from_lovelace(10000000), fake_state_hash, "", 1),
        address: Address(ScriptCredential(fake_state_hash), None),
        datum: InlineDatum(cdp_datum),
        reference_script: None,
      },
    ]
  create_transitions(
    fake_mint_hash,
    fake_state_hash,
    1000,
    3000,
    [usd_params()],
    [usd_price()],
    [list.length(cdp_outputs)],
    push_to_tail(cdp_outputs, change_output()),
    dict.new(),
    0,
    value.zero(),
    0,
  ).1st == {
    let sds = {
      let cdp_output <- list.map(cdp_outputs)
      create_transitions(
        fake_mint_hash,
        fake_state_hash,
        1000,
        3000,
        [usd_params()],
        [usd_price()],
        [1],
        [cdp_output, change_output()],
        dict.new(),
        0,
        value.zero(),
        0,
      ).1st
    }
    let
      types.StateDelta {
        mint: x_mint,
        btn_delta: x_delta,
        fee: x_fee,
        lock_mints: x_lock,
      },
      types.StateDelta {
        mint: y_mint,
        btn_delta: y_delta,
        fee: y_fee,
        lock_mints: y_lock,
      },
    <-
      list.reduce(
        sds,
        types.StateDelta {
          mint: dict.new(),
          btn_delta: 0,
          fee: value.zero(),
          lock_mints: 0,
        },
      )
    types.StateDelta {
      mint: dict.union_with(
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
      btn_delta: x_delta + y_delta,
      fee: value.merge(x_fee, y_fee),
      lock_mints: x_lock + y_lock,
    }
  }
}

fn create_composition_fuzzes() {
  let fake_mint_hash <- fuzz.and_then(fuzzers.script_hash())
  let fake_state_hash <- fuzz.and_then(fuzzers.script_hash())
  let cdp_outputs <-
    fuzz.map(
      fuzz.list(
        fuzzers.overcollateralised_cdp(
          fake_mint_hash,
          fake_state_hash,
          usd_params(),
          usd_price(),
        ),
      ),
    )
  (fake_mint_hash, fake_state_hash, cdp_outputs)
}

test create_composition(stuff via create_composition_fuzzes()) {
  let (fake_mint_hash, fake_state_hash, cdp_outputs) = stuff
  create_transitions(
    fake_mint_hash,
    fake_state_hash,
    1000,
    3000,
    [usd_params()],
    [usd_price()],
    [list.length(cdp_outputs)],
    push_to_tail(cdp_outputs, change_output()),
    dict.new(),
    0,
    value.zero(),
    0,
  ).1st == {
    let sds = {
      let cdp_output <- list.map(cdp_outputs)
      create_transitions(
        fake_mint_hash,
        fake_state_hash,
        1000,
        3000,
        [usd_params()],
        [usd_price()],
        [1],
        [cdp_output, change_output()],
        dict.new(),
        0,
        value.zero(),
        0,
      ).1st
    }
    let
      types.StateDelta {
        mint: x_mint,
        btn_delta: x_delta,
        fee: x_fee,
        lock_mints: x_lock,
      },
      types.StateDelta {
        mint: y_mint,
        btn_delta: y_delta,
        fee: y_fee,
        lock_mints: y_lock,
      },
    <-
      list.reduce(
        sds,
        types.StateDelta {
          mint: dict.new(),
          btn_delta: 0,
          fee: value.zero(),
          lock_mints: 0,
        },
      )
    types.StateDelta {
      mint: dict.union_with(
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
      btn_delta: x_delta + y_delta,
      fee: value.merge(x_fee, y_fee),
      lock_mints: x_lock + y_lock,
    }
  }
}

test undercollateralised_fails(
  cdp_outputs via fuzz.list_at_least(
    fuzzers.undercollateralised_cdp(
      fake_mint_hash,
      fake_state_hash,
      usd_params(),
      usd_price(),
    ),
    1,
  ),
) fail {
  let (a, _b) =
    create_transitions(
      fake_mint_hash,
      fake_state_hash,
      1000,
      3000,
      [usd_params()],
      [usd_price()],
      [list.length(cdp_outputs)],
      push_to_tail(cdp_outputs, change_output()),
      dict.new(),
      0,
      value.zero(),
      0,
    )
  a.lock_mints >= 0
}
