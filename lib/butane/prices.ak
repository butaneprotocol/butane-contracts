use aiken/builtin
use aiken/dict.{Dict}
use aiken/math
use aiken/math/rational.{Rational}
use aiken/transaction/value.{AssetName, PolicyId, Value}
use butane/types
use butane/unsafe

// Gets the raw collateralization ratio (CR) and health factor (HF) of a CDP
pub fn get_collateral_finances(
  p_list: List<Int>,
  p_dom: Int,
  v: Value,
  assets: List<types.AssetClass>,
  w_list: List<Int>,
  w_dom: Int,
  max_proportions_list: List<Int>,
  synth_amount: Int,
  callback: fn(Rational, Rational) -> a,
) -> a {
  let v2: Pairs<PolicyId, Dict<AssetName, Int>> =
    v |> value.to_dict |> dict.to_pairs
  let unweighted_capacity, capacity <-
    do_get_borrowing_capacity(
      u_value: v2,
      debt: synth_amount,
      unweighted_capacity: 0,
      borrowing_capacity: 0,
      collateral_assets: assets,
      collateral_prices: p_list,
      prices_denom: p_dom,
      weights_denom: w_dom,
      collateral_weights: w_list,
      collateral_max_proportions: max_proportions_list,
      callback: _,
    )
  let cr =
    unsafe.unsome(rational.new(unweighted_capacity, p_dom * synth_amount))
  let hf = unsafe.unsome(rational.new(capacity, synth_amount))
  callback(cr, hf)
}

pub fn do_get_borrowing_capacity(
  u_value: Pairs<PolicyId, Dict<AssetName, Int>>,
  debt: Int,
  unweighted_capacity: Int,
  borrowing_capacity: Int,
  collateral_assets: List<types.AssetClass>,
  collateral_prices: List<Int>,
  prices_denom: Int,
  weights_denom: Int,
  collateral_weights: List<Int>,
  collateral_max_proportions: List<Int>,
  callback: fn(Int, Int) -> a,
) -> a {
  when u_value is {
    [Pair(pol, pol_v), ..vs] ->
      do_get_borrowing_capacity_2(
        pol: pol,
        pol_v: pol_v |> dict.to_pairs,
        and_finally: do_get_borrowing_capacity(vs, _, _, _, _, _, _, _, _, _, _),
        debt: debt,
        unweighted_capacity: unweighted_capacity,
        borrowing_capacity: borrowing_capacity,
        collateral_assets: collateral_assets,
        collateral_prices: collateral_prices,
        prices_denom: prices_denom,
        weights_denom: weights_denom,
        collateral_weights: collateral_weights,
        collateral_max_proportions: collateral_max_proportions,
        callback: callback,
      )
    _ -> callback(unweighted_capacity, borrowing_capacity)
  }
}

pub fn do_get_borrowing_capacity_2(
  pol: PolicyId,
  pol_v: Pairs<AssetName, Int>,
  and_finally: fn(
    Int,
    Int,
    Int,
    List<types.AssetClass>,
    List<Int>,
    Int,
    Int,
    List<Int>,
    List<Int>,
    fn(Int, Int) -> a,
  ) ->
    a,
  debt: Int,
  unweighted_capacity: Int,
  borrowing_capacity: Int,
  collateral_assets: List<types.AssetClass>,
  collateral_prices: List<Int>,
  prices_denom: Int,
  weights_denom: Int,
  collateral_weights: List<Int>,
  collateral_max_proportions: List<Int>,
  callback: fn(Int, Int) -> a,
) -> a {
  when pol_v is {
    [Pair(token_name, qty), ..vs] ->
      get_asset_price_then(
        s: types.AssetClass { policy_id: pol, asset_name: token_name },
        debt: debt,
        unweighted_capacity: unweighted_capacity,
        borrowing_capacity: borrowing_capacity,
        qty: qty,
        asset_list: collateral_assets,
        price_list: collateral_prices,
        prices_denom: prices_denom,
        weights_denom: weights_denom,
        weights_list: collateral_weights,
        max_proportion_list: collateral_max_proportions,
        continue_with: do_get_borrowing_capacity_2(
          pol,
          vs,
          and_finally,
          _,
          _,
          _,
          _,
          _,
          _,
          _,
          _,
          _,
          _,
        ),
        callback: callback,
      )
    _ ->
      and_finally(
        debt,
        unweighted_capacity,
        borrowing_capacity,
        collateral_assets,
        collateral_prices,
        prices_denom,
        weights_denom,
        collateral_weights,
        collateral_max_proportions,
        callback,
      )
  }
}

fn get_asset_price_then(
  s: types.AssetClass,
  debt: Int,
  unweighted_capacity: Int,
  borrowing_capacity: Int,
  qty: Int,
  asset_list: List<types.AssetClass>,
  price_list: List<Int>,
  prices_denom: Int,
  weights_denom: Int,
  weights_list: List<Int>,
  max_proportion_list: List<Int>,
  continue_with: fn(
    Int,
    Int,
    Int,
    List<types.AssetClass>,
    List<Int>,
    Int,
    Int,
    List<Int>,
    List<Int>,
    fn(Int, Int) -> a,
  ) ->
    a,
  callback: fn(Int, Int) -> a,
) -> a {
  expect [asset_name, ..] = asset_list
  if s == asset_name {
    expect [price, ..] = price_list
    let numerator = qty * price
    continue_with(
      debt,
      unweighted_capacity + numerator,
      borrowing_capacity + math.min(
        // First case: the asset is not limited by the max proportion
        numerator * weights_denom / builtin.head_list(weights_list) / prices_denom,
        // Second case: the asset is limited by the max proportion
        debt * builtin.head_list(max_proportion_list) / types.bp_precision,
      ),
      builtin.tail_list(asset_list),
      builtin.tail_list(price_list),
      prices_denom,
      weights_denom,
      builtin.tail_list(weights_list),
      builtin.tail_list(max_proportion_list),
      callback,
    )
  } else {
    get_asset_price_then(
      s: s,
      debt: debt,
      unweighted_capacity: unweighted_capacity,
      borrowing_capacity: borrowing_capacity,
      qty: qty,
      asset_list: builtin.tail_list(asset_list),
      price_list: builtin.tail_list(price_list),
      prices_denom: prices_denom,
      weights_denom: weights_denom,
      weights_list: builtin.tail_list(weights_list),
      max_proportion_list: builtin.tail_list(max_proportion_list),
      continue_with: continue_with,
      callback: callback,
    )
  }
}

test basic_bc_test() {
  let
    a,
    b,
  <-
    do_get_borrowing_capacity(
      value.from_asset("", "", 10)
        |> value.to_dict
        |> dict.to_pairs,
      100,
      0,
      0,
      [types.AssetClass { policy_id: "", asset_name: "" }],
      [2],
      1,
      1,
      [3],
      [10_000],
    )
  (a, b) == (20, 6)
}

test basic_bc_test_2() {
  let
    a,
    b,
  <-
    do_get_borrowing_capacity(
      value.from_asset("", "", 10)
        |> value.merge(value.from_asset("a", "b", 20))
        |> value.to_dict
        |> dict.to_pairs,
      100,
      0,
      0,
      [
        types.AssetClass { policy_id: "", asset_name: "" },
        types.AssetClass { policy_id: "a", asset_name: "b" },
      ],
      [2, 2],
      1,
      1,
      [3, 3],
      [10_000, 10_000],
    )
  (a, b) == (60, 19)
}

test basic_bc_test_m() {
  let
    a,
    b,
  <-
    do_get_borrowing_capacity(
      value.from_asset("", "", 10)
        |> value.merge(value.from_asset("a", "b", 20))
        |> value.merge(value.from_asset("c", "d", 20))
        |> value.merge(value.from_asset("e", "f", 20))
        |> value.merge(value.from_asset("g", "h", 20))
        |> value.merge(value.from_asset("i", "j", 20))
        |> value.to_dict
        |> dict.to_pairs,
      100,
      0,
      0,
      [
        types.AssetClass { policy_id: "", asset_name: "" },
        types.AssetClass { policy_id: "a", asset_name: "b" },
        types.AssetClass { policy_id: "c", asset_name: "d" },
        types.AssetClass { policy_id: "e", asset_name: "f" },
        types.AssetClass { policy_id: "g", asset_name: "h" },
        types.AssetClass { policy_id: "i", asset_name: "j" },
      ],
      [2, 2, 2, 2, 2, 2],
      1,
      1,
      [3, 3, 3, 3, 3, 3],
      [10_000, 10_000, 10_000, 10_000, 10_000, 10_000],
    )
  (a, b) == (220, 71)
}
