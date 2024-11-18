use aiken/builtin
use aiken/list
use aiken/transaction.{ScriptContext}
use butane/types

/// Script for handling price feeds. Validates price feed signatures
validator(
  /// The verification key for the price feed to validate signed feeds
  verification_key: ByteArray,
) {
  fn check_feed(
    redeemer: Data<types.PriceFeedRedeemer>,
    _ctx: ScriptContext,
  ) -> Bool {
    expect redeemer: List<types.Feed<Data, ByteArray>> = redeemer
    // verify each Data when serialised is signed via ByteArray
    list.all(
      redeemer,
      fn(feed) {
        let types.Feed { data, extra: signature } = feed
        builtin.verify_ed25519_signature(
          verification_key,
          builtin.serialise_data(data),
          signature,
        )?
      },
    )
  }
}

// Only used to access the type in blueprints
validator {
  fn feed_inner_type(_redeemer: types.PriceFeed, _ctx: ScriptContext) -> Bool {
    False
  }
}
