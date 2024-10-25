use aiken/interval.{Finite, Interval, IntervalBound}
use aiken/transaction.{NoDatum, Output}
use aiken/transaction/credential.{Address, ScriptCredential}
use aiken/transaction/value
use butane/types

pub const fake_mint_hash =
  #"4fe5fcedb7f1061f9e9c25d1811cba7a5b452be6a3669a8b81e1ac0a44aa3f9e"

pub const fake_state_hash =
  #"4fe5fcedb7f1061f9e9c25d1811cba7a5b452be6a3669a8b81e1ac0a44aa3f9e"

pub const fake_leftovers_hash =
  #"4fe5fcedb7f1061f9e9c25d1811cba7a5b452be6a3669a8b81e1ac0a44aa3f9e"

pub fn fake_asset_class() {
  types.AssetClass { policy_id: "", asset_name: "" }
}

pub fn change_output() {
  Output {
    value: value.zero(),
    address: Address(ScriptCredential(""), None),
    datum: NoDatum,
    reference_script: None,
  }
}

pub fn usd_params() {
  types.ParamsData {
    params: types.LiveParams {
      params: types.ActiveParams {
        collateral_assets: [types.AssetClass("", "")],
        weights: [110],
        denominator: 100,
        minimum_outstanding_synthetic: 0,
        interest_rates: [(200, 200)],
        max_proportions: [10000],
        max_liquidation_return: 10000,
        treasury_liquidation_share: 1,
        redemption_share: 0,
        fee_token_discount: 0,
        staking_interest_rates: [(200, 200)],
      },
    },
    synthetic: "USD",
  }
}

pub fn usd_price() {
  types.PriceFeed {
    collateral_prices: [100],
    synthetic: "USD",
    denominator: 1,
    validity: non_interval(),
  }
}

pub fn non_interval() {
  Interval {
    lower_bound: IntervalBound { bound_type: Finite(2000), is_inclusive: False },
    upper_bound: IntervalBound {
      bound_type: Finite(10000),
      is_inclusive: False,
    },
  }
}
