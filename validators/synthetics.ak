use aiken/builtin
use aiken/list
use aiken/option
use aiken/pairs
use aiken/transaction.{ScriptContext, Transaction, WithdrawFrom}
use aiken/transaction/credential.{Inline, ScriptCredential}
use butane/subvalidators/bad_debt.{bad_debt}
use butane/subvalidators/cdp_script.{cdp_script}
use butane/subvalidators/gov_issue.{consume_external, gov_issue}
use butane/subvalidators/next_compat.{compat_locking}
use butane/subvalidators/params_script.{params_init, params_update, params_void}
use butane/subvalidators/staking.{staking_script}
use butane/subvalidators/treasury.{
  treasury_create_debt, treasury_mint, treasury_redeem, treasury_reward_withdraw,
  treasury_spend, treasury_stake_update,
}
use butane/subvalidators/voided_synth.{collect_voided_cdp}
use butane/types
use butane/utils

/// Main validator which handles CDP creation/spending transactions
validator(
  /// The token used for fees
  fee_token: types.AssetClass,
  /// The script hash where synthetics are minted from, and also delegation/withdrawals happen from
  mint_script_hash: types.ScriptHash,
  /// The script hash where protocol outputs are stored and spent from
  spend_script_hash: types.ScriptHash,
  /// The hash of the leftovers script
  leftovers_script_hash: types.ScriptHash,
  /// The NFT which authorizes CDP redemptions
  redemptions_nft: types.AssetClass,
  /// External script governance validation logic is deferred to
  gov_script_hash: types.ScriptHash,
  /// External script treasury validation logic is deferred to
  treasury_script_hash: types.ScriptHash,
  /// Hash of price feed validator
  price_feed_script_hash: types.ScriptHash,
  // External script stake validation logic is deferred to
  stake_script_hash: types.ScriptHash,
) {
  fn validate(redeemer: types.PolicyRedeemer, ctx: ScriptContext) -> Bool {
    expect ScriptContext {
      purpose: WithdrawFrom(_),
      transaction: Transaction {
        withdrawals,
        redeemers,
        inputs,
        outputs,
        reference_inputs,
        mint,
        validity_range,
        extra_signatories,
        certificates,
        ..
      },
    } = ctx

    let no_certs =
      fn() {
        let mint_stake_cred: Data = Inline(ScriptCredential(mint_script_hash))
        let certificate <- list.all(certificates)
        // Can't do any certificate action that uses the mint script (delegator is always the first field)
        ( builtin.un_constr_data(certificate).2nd |> builtin.head_list() ) != mint_stake_cred
      }

    let zero_withdrawals =
      fn() {
        utils.not_withdrawing_from(
          withdrawals,
          Inline(ScriptCredential(mint_script_hash)),
        )
      }

    let no_certs_or_withdrawals =
      fn() { no_certs() && zero_withdrawals() }

    when redeemer is {
      types.SyntheticsMain { spends, creates } ->
        cdp_script(
          mint,
          outputs,
          redeemers,
          inputs,
          reference_inputs,
          extra_signatories,
          validity_range,
          withdrawals,
          mint_script_hash,
          spend_script_hash,
          spends,
          creates,
          price_feed_script_hash,
          leftovers_script_hash,
          fee_token,
          redemptions_nft,
        ) && no_certs_or_withdrawals()
      types.CollectVoidedCDP { verifier } ->
        collect_voided_cdp(
          verifier,
          mint,
          extra_signatories,
          inputs,
          withdrawals,
          validity_range,
          reference_inputs,
          mint_script_hash,
          spend_script_hash,
        ) && no_certs_or_withdrawals()
      types.BadDebt { treasury_out_idx } ->
        bad_debt(
          inputs,
          outputs,
          reference_inputs,
          redeemers,
          validity_range,
          mint,
          spend_script_hash,
          price_feed_script_hash,
          mint_script_hash,
          treasury_out_idx,
        ) && no_certs_or_withdrawals()
      types.Auxilliary -> {
        expect Some(aux_redeemer) =
          redeemers
            |> pairs.get_first(
                WithdrawFrom(Inline(ScriptCredential(gov_script_hash))),
              )
            |> option.or_try(
                fn() {
                  pairs.get_first(
                    redeemers,
                    WithdrawFrom(Inline(ScriptCredential(treasury_script_hash))),
                  )
                },
              )
            |> option.or_try(
                fn() {
                  pairs.get_first(
                    redeemers,
                    WithdrawFrom(Inline(ScriptCredential(stake_script_hash))),
                  )
                },
              )
        expect aux: types.AuxilliaryRedeemer = aux_redeemer
        and {
          (aux == types.TreasuryDelegate || no_certs())?,
          (aux == types.TreasuryGetRewards || zero_withdrawals())?,
        }
      }
    }
  }
}

/// External validator which handles governance redeemer endpoints
validator(
  /// Token used for Butane governance
  gov_nft: types.AssetClass,
  /// The script hash where synthetics are minted from, and also delegation/withdrawals happen from
  mint_script_hash: types.ScriptHash,
  /// The script hash where protocol outputs are stored and spent from
  spend_script_hash: ByteArray,
  /// The token used for fees
  fee_token: types.AssetClass,
  /// Hash of price feed validator
  price_feed_script_hash: types.ScriptHash,
) {
  fn external_gov_validate(
    aux_redeemer: types.AuxilliaryRedeemer,
    ctx: ScriptContext,
  ) {
    expect ScriptContext { transaction, purpose: WithdrawFrom(..) } = ctx
    let Transaction {
      withdrawals,
      redeemers,
      inputs,
      outputs,
      reference_inputs,
      mint,
      validity_range,
      ..
    } = transaction

    when aux_redeemer is {
      types.ParamsMint { oidx } ->
        params_init(
          mint,
          outputs,
          inputs,
          validity_range,
          mint_script_hash,
          spend_script_hash,
          oidx,
          fee_token,
        )
      types.ParamsUpdate { oidx, reverse_order } ->
        params_update(
          mint,
          outputs,
          validity_range,
          inputs,
          mint_script_hash,
          spend_script_hash,
          oidx,
          reverse_order,
        )
      types.ParamsVoid ->
        params_void(
          mint,
          inputs,
          redeemers,
          outputs,
          mint_script_hash,
          price_feed_script_hash,
          spend_script_hash,
          validity_range,
        )
      types.GovernanceIssue { output_idx } ->
        gov_issue(
          inputs,
          outputs,
          mint,
          gov_nft,
          spend_script_hash,
          mint_script_hash,
          output_idx,
        )
      types.ExternalGovernance ->
        consume_external(
          inputs,
          mint,
          withdrawals,
          spend_script_hash,
          mint_script_hash,
        )
      types.Compatibility { inner } ->
        compat_locking(
          inputs,
          reference_inputs,
          outputs,
          mint,
          spend_script_hash,
          mint_script_hash,
          inner,
        )
      _ ->
        fail @"Wrong auxilliary script -- use treasury/stake validator instead"
    }
  }
}

/// External validator which handles treasury redeemer endpoints
validator(
  /// The script hash where synthetics are minted from, and also delegation/withdrawals happen from
  mint_script_hash: types.ScriptHash,
  /// The script hash where protocol outputs are stored and spent from
  spend_script_hash: ByteArray,
  /// Hash of price feed validator
  price_feed_script_hash: types.ScriptHash,
) {
  fn external_treas_validate(
    aux_redeemer: types.AuxilliaryRedeemer,
    ctx: ScriptContext,
  ) {
    expect ScriptContext { transaction, purpose: WithdrawFrom(..) } = ctx
    let Transaction {
      withdrawals,
      redeemers,
      inputs,
      outputs,
      reference_inputs,
      mint,
      validity_range,
      certificates,
      ..
    } = transaction

    when aux_redeemer is {
      types.TreasurySpend { expected_output_idx, gov_inp_idx, inputs_from_fees } ->
        treasury_spend(
          inputs,
          outputs,
          mint,
          spend_script_hash,
          mint_script_hash,
          expected_output_idx,
          gov_inp_idx,
          inputs_from_fees,
        )
      types.TreasuryMint { expected_output_idx } ->
        treasury_mint(
          inputs,
          outputs,
          mint,
          spend_script_hash,
          mint_script_hash,
          expected_output_idx,
        )
      types.TreasuryCreateDebt { expected_output_idx } ->
        treasury_create_debt(
          inputs,
          reference_inputs,
          outputs,
          mint,
          spend_script_hash,
          mint_script_hash,
          expected_output_idx,
        )
      types.TreasuryRedemption { lock_burned, inputs_from_fees } ->
        treasury_redeem(
          inputs,
          reference_inputs,
          redeemers,
          mint,
          outputs,
          validity_range,
          spend_script_hash,
          mint_script_hash,
          price_feed_script_hash,
          lock_burned,
          inputs_from_fees,
        )
      types.TreasuryDelegate ->
        treasury_stake_update(
          inputs,
          mint,
          certificates,
          spend_script_hash,
          mint_script_hash,
        )
      types.TreasuryGetRewards ->
        treasury_reward_withdraw(
          inputs,
          mint,
          outputs,
          withdrawals,
          spend_script_hash,
          mint_script_hash,
        )
      _ ->
        fail @"Wrong auxilliary script -- use governance/stake validator instead"
    }
  }
}

/// External validator which handles staking endpoints
validator(
  /// The script hash where synthetics are minted from, and also delegation/withdrawals happen from
  mint_script_hash: types.ScriptHash,
  /// The script hash where protocol outputs are stored and spent from
  spend_script_hash: ByteArray,
) {
  fn external_staking_validate(
    aux_redeemer: types.AuxilliaryRedeemer,
    ctx: ScriptContext,
  ) {
    expect ScriptContext { transaction, purpose: WithdrawFrom(..) } = ctx
    let Transaction {
      withdrawals,
      inputs,
      outputs,
      reference_inputs,
      mint,
      validity_range,
      extra_signatories,
      ..
    } = transaction

    when aux_redeemer is {
      types.Staking(staking_redeemer) ->
        staking_script(
          mint_script_hash,
          spend_script_hash,
          withdrawals,
          inputs,
          outputs,
          reference_inputs,
          mint,
          validity_range,
          extra_signatories,
          staking_redeemer,
        )
      _ ->
        fail @"Wrong auxilliary script -- use treasury/governance validator instead"
    }
  }
}

validator {
  fn global_type(_d: types.GlobalDatum, _ctx) {
    False
  }
}
