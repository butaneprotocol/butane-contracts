use aiken/interval.{Finite, Interval, IntervalBound}
use aiken/transaction.{ScriptContext, Spend, Transaction}
use butane/types
use butane/utils

/// Validator to handle leftover collateral from CDP transactions
validator {
  fn collect(
    datum: types.LeftoversDatum,
    redeemer: types.CDPCredentialVerifier,
    ctx: ScriptContext,
  ) -> Bool {
    expect ScriptContext {
      transaction: Transaction {
        extra_signatories,
        inputs,
        withdrawals,
        validity_range,
        ..
      },
      purpose: Spend(this_oref),
    } = ctx

    expect Interval {
      lower_bound: IntervalBound { bound_type: Finite(valid_from), .. },
      upper_bound: IntervalBound { bound_type: Finite(valid_to), .. },
    } = validity_range

    utils.authorization_check(
      datum.owner,
      this_oref,
      redeemer,
      extra_signatories,
      inputs,
      withdrawals,
      valid_from,
      valid_to,
    )?
  }
}
