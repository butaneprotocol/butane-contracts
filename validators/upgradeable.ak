use aiken/builtin
use aiken/dict
use aiken/list
use aiken/pairs
use aiken/transaction.{
  Input, Mint, OutputReference, ScriptContext, Transaction, WithdrawFrom,
}
use aiken/transaction/credential.{Inline, ScriptCredential}
use aiken/transaction/value
use butane/types

pub fn find_input(el: Data, list: List<Input>) {
  expect [head, ..tail] = list
  let oref: Data = head.output_reference
  if oref == el {
    head
  } else {
    find_input(el, tail)
  }
}

validator(
  init_utxo: OutputReference,
  /// Arbitrary number for mining to ensure that the upgradeable validator comes before the price feeds validator in the withdrawals list
  _salt: Int,
) {
  fn control_state(redeemer: Data, ctx: ScriptContext) -> Bool {
    let ScriptContext { transaction: tx, purpose } = ctx

    when purpose is {
      WithdrawFrom(cred) -> {
        expect Inline(ScriptCredential(own_hash)) = cred
        let Transaction { reference_inputs, withdrawals, .. } = tx
        let input = find_input(redeemer, reference_inputs)
        expect [Pair(token_name, _)] =
          input.output.value |> value.tokens(own_hash) |> dict.to_pairs

        let withdraw_cred = Inline(ScriptCredential(token_name))

        pairs.has_key(withdrawals, withdraw_cred)
      }

      Mint(own_policy) -> {
        let Transaction { inputs, mint, .. } = tx

        expect redeemer: types.ControlAction = redeemer

        when redeemer is {
          types.InitMint -> {
            expect
              list.any(inputs, fn(inp) { inp.output_reference == init_utxo })

            expect [Pair(name, minted_amount)] =
              mint
                |> value.from_minted_value
                |> value.tokens(own_policy)
                |> dict.to_pairs

            // The new token must have a name of 28 bytes
            // Expect one minted token
            and {
              minted_amount == 1,
              builtin.length_of_bytearray(name) == 28,
            }
          }

          types.Upgrade -> {
            // Expect one token minted and one token burned
            // The new token must have a name of 28 bytes
            expect [Pair(name1, minted_amount1), Pair(name2, minted_amount2)] =
              mint
                |> value.from_minted_value
                |> value.tokens(own_policy)
                |> dict.to_pairs

            or {
              and {
                minted_amount1 == 1,
                minted_amount2 == -1,
                builtin.length_of_bytearray(name1) == 28,
              },
              and {
                minted_amount1 == -1,
                minted_amount2 == 1,
                builtin.length_of_bytearray(name2) == 28,
              },
            }
          }
        }
      }

      _ -> False
    }
  }
}

validator {
  fn oref_type(_r: OutputReference, _ctx) {
    False
  }
}

validator {
  fn init_type(_r: types.ControlAction, _ctx) {
    False
  }
}
