use aiken/pairs.{has_key}
use aiken/transaction.{ScriptContext}
use aiken/transaction/credential.{Credential, Referenced}
use butane/types

validator(upgradeable_script_hash: Referenced<Credential>) {
  fn spend(
    _datum: Data<types.MonoDatum>,
    _redeemer: Data,
    ctx: ScriptContext,
  ) -> Bool {
    has_key(ctx.transaction.withdrawals, upgradeable_script_hash)
  }
}

validator(
  upgradeable_script_hash: Referenced<Credential>,
  /// Arbitrary number for mining to ensure that the minting policy is low (vanity reasons)
  _salt: Int,
) {
  fn mint(_redeemer: Data, ctx: ScriptContext) -> Bool {
    has_key(ctx.transaction.withdrawals, upgradeable_script_hash)
  }
}
