use aiken/fuzz
use aiken/list
use aiken/transaction.{InlineDatum, Output}
use aiken/transaction/credential.{Address, Inline, ScriptCredential}
use aiken/transaction/value.{Value}
use butane/types

pub fn script_hash() -> Fuzzer<ByteArray> {
  fuzz.bytearray()
}

pub fn collateral(
  params: types.ParamsData,
  prices: types.PriceFeed,
) -> Fuzzer<(Value, Int)> {
  expect types.LiveParams{params: types.ActiveParams {
    collateral_assets,
    weights,
    denominator: param_denom,
    ..
  }} = params.params
  let types.PriceFeed { collateral_prices, denominator: price_denom, .. } =
    prices
  let index <-
    fuzz.and_then(fuzz.int_between(0, list.length(collateral_assets) - 1))
  expect Some(collateral) = collateral_assets |> list.at(index)
  expect Some(price) = collateral_prices |> list.at(index)
  expect Some(weight) = weights |> list.at(index)
  let c <- fuzz.and_then(fuzz.int_between(1000000, 100000000))
  let bc = price * c * param_denom / weight / price_denom
  fuzz.constant(
    (value.from_asset(collateral.policy_id, collateral.asset_name, c), bc),
  )
}

pub fn overcollateralised_cdp(
  fake_mint_hash: ByteArray,
  fake_state_hash: ByteArray,
  params: types.ParamsData,
  prices: types.PriceFeed,
) -> Fuzzer<Output> {
  let cr <- fuzz.and_then(fuzz.int_between(11000, 14000))
  do_cdp(fake_mint_hash, fake_state_hash, params, prices, cr)
}

pub fn undercollateralised_cdp(
  fake_mint_hash: ByteArray,
  fake_state_hash: ByteArray,
  params: types.ParamsData,
  prices: types.PriceFeed,
) -> Fuzzer<Output> {
  let cr <- fuzz.and_then(fuzz.int_between(6000, 9000))
  do_cdp(fake_mint_hash, fake_state_hash, params, prices, cr)
}

pub fn do_cdp(
  fake_mint_hash: ByteArray,
  fake_state_hash: ByteArray,
  params: types.ParamsData,
  prices: types.PriceFeed,
  cr: Int,
) {
  let (val, mint) <- fuzz.and_then(collateral(params, prices))
  let owner_hash <- fuzz.and_then(script_hash())
  let cdp_datum =
    types.CDP {
      owner: types.AuthorizeWithConstraint(
        types.MustWithdrawFrom(Inline(ScriptCredential(owner_hash))),
      ),
      synthetic_asset: "USD",
      synthetic_amount: mint * 10000 / cr,
      start_time: 1000,
    }
  fuzz.constant(
    Output {
      value: value.add(
        value.merge(value.from_lovelace(0), val),
        fake_mint_hash,
        "",
        1,
      ),
      address: Address(ScriptCredential(fake_state_hash), None),
      datum: InlineDatum(cdp_datum),
      reference_script: None,
    },
  )
}
