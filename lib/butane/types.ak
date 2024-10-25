use aiken/dict.{Dict}
use aiken/hash.{Blake2b_224, Hash}
use aiken/time.{PosixTime}
use aiken/transaction.{Datum, OutputReference, ValidityRange}
use aiken/transaction/credential.{
  Address, PoolId, Script, StakeCredential, VerificationKey,
}
use aiken/transaction/value.{AssetName, PolicyId, Value}

// Constants
/// Rough upper bound on minAda
pub const max_min_ada = 2_000_000

/// Name of the CDP lock tokens
pub const cdp_lock_token_name = ""

// Name of the staking lock tokens
pub const staking_lock_token_name = "STK"

/// Name of the governance lock token
pub const gov_lock_token_name = "gov"

/// Prefix for all synthetic parameter tokens
pub const params_prefix = "p_"

/// Length of params_prefix
pub const params_prefix_length = 2

/// Prefix for all aribtrary debt tokens
pub const debt_prefix = "d_"

/// Length of debt_prefix
pub const debt_prefix_length = 2

/// The precision of basis points
pub const bp_precision = 10_000

/// Time constants
pub const milliseconds_in_year = 31_536_000_000

pub const milliseconds_in_week = 604_800_000

pub const milliseconds_in_day = 86_400_000

/// The number of historical interest rates stored in synthetic parameters
pub const num_stored_interest_rates = 71

pub type ControlAction {
  InitMint
  Upgrade
}

// Helper types
/// Hash of a public key
pub type PubKeyHash =
  Hash<Blake2b_224, VerificationKey>

/// Hash of a script
pub type ScriptHash =
  Hash<Blake2b_224, Script>

/// A cardano asset
pub type AssetClass {
  /// The policy id of the asset
  policy_id: PolicyId,
  /// The name of the asset
  asset_name: AssetName,
}

// Authorization types
/// The owner of a CDP
pub type CDPCredential {
  /// Owner is a public key
  AuthorizeWithPubKey(PubKeyHash, VerificationKey)
  /// Owner is defined by a constraint
  AuthorizeWithConstraint(Constraint)
}

/// A constraint on a CDP
pub type Constraint {
  /// The owner is defined by the spending of a token
  MustSpendToken(AssetClass)
  /// The owner is defined by a script that must be withdrawn from
  MustWithdrawFrom(StakeCredential)
}

pub type ConstraintCredential {
  utxo: OutputReference,
  interval: ValidityRange,
  constraint: Constraint,
}

pub type CDPSubVerifier {
  AuthorizedWithExtraSigs
  AuthorizedWithInputsOref(OutputReference)
  AuthorizedWithWithdrawal
}

pub type CDPCredentialVerifier {
  AuthorizingDirectly(CDPSubVerifier)
  AuthorizingOtherWithSignature {
    other: ConstraintCredential,
    sub_verifier: CDPSubVerifier,
    signature: ByteArray,
  }
}

/// Keeps a running track of the expected state change at the end of a CDP transaction
pub type StateDelta {
  mint: Dict<AssetName, Int>,
  btn_delta: Int,
  fee: Value,
  lock_mints: Int,
}

/// Parameters with their associated synthetic named (grabbed from the value of the params UTxO)
pub type ParamsData {
  params: Params,
  synthetic: AssetName,
}

/// Created debt that lets the treasury be redeemed by anyone who can burn the debt amount
pub type TreasuryDebt {
  amount: Int,
  asset: AssetName,
}

/// Stores global configurations
pub type GlobalDatum {
  /// The hash of the price feed script
  price_feed_script_hash: ScriptHash,
  /// Extra data used for governance. Ignored in these scripts
  gov_data: Data,
}

/// Datum used by all UTxOs as the CDP script
pub type MonoDatum {
  /// Parameters for a given synthetic
  ParamsWrapper {
    /// The synthetic parameters
    params: Params,
  }
  /// A CDP
  CDP {
    /// The owner of a CDP, can be a pubkey or a constraint
    owner: CDPCredential,
    /// The synthetic asset the CDP is minting
    synthetic_asset: AssetName,
    /// The amount of the synthetic minted
    synthetic_amount: Int,
    /// The opening time of the CDP, given as the lower bound of the validity range
    start_time: PosixTime,
  }
  /// A governance action
  GovDatum {
    /// The governance action
    gov: GovAction,
  }
  /// An output handled by the treasury
  TreasuryDatum {
    /// The type of treasury output
    treas: TreasuryDatum,
  }
  /// Locked tokens for a future protocol version
  CompatLockedTokens
  StakedSynthetics {
    owner: CDPCredential,
    synthetic_asset: AssetName,
    start_time: PosixTime,
  }
}

pub type TreasuryDatum {
  /// i.e collected from the "BadDebtCollection" endpoint
  TreasuryWithDebt { debt: TreasuryDebt, creation_time: Option<PosixTime> }
  /// Treasury deposited at genesis (cannot be collected via redemptions)
  TreasuryFromGenesis
  /// Treasury deposited via fees (can be spent via redemptions & governance)
  TreasuryFromFees
  /// Treasury that can only be used for redemptions
  TreasuryOnlyRedeem
  /// Treasury that can only be used for spending
  TreasuryOnlySpend
}

/// After a liquidation / a redemption with leftovers, orginal CDP owner can claim
pub type LeftoversDatum {
  /// Owner of the leftovers, can be a pubkey or a constraint
  owner: CDPCredential,
}

/// Non-Opaque version of Output for blueprint
pub type FakeOutput {
  address: Address,
  value: List<(PolicyId, List<(AssetName, Int)>)>,
  datum: Datum,
  reference_script: Option<Hash<Blake2b_224, Script>>,
}

/// The type of governance action
pub type GovAction {
  /// Creation of new parameters for a synthetic
  NewParamsAuth {
    /// The new parameters
    params: Params,
    /// Synthetic asset name to create parameters for
    asset: AssetName,
  }
  /// Updating of the parameters for a synthetic
  UpdateParamsAuth {
    /// Synthetic asset name to update parameters for
    asset: AssetName,
    /// The type of update
    action: ParamAction,
  }
  /// Spending from the treasury
  TreasurySpendAuth {
    /// The output to create after spending
    out: FakeOutput,
  }
  /// Minting assets via the treasury
  TreasuryMintAuth {
    /// The asset to mint
    asset: AssetName,
    /// The amount to mint
    amount: Int,
  }
  /// Creating debt for the treasury that can be redeemed
  TreasuryCreateDebtAuth {
    /// Details of the debt
    debt: TreasuryDebt,
  }
  /// Arbitrary text proposal
  TextProposalAuth {
    /// Details of the proposal
    text: ByteArray,
  }
  /// Updating of the treasury's stake delegation
  TreasuryStakeUpdate {
    /// The pool to delegate to
    delegatee: PoolId,
  }
  /// Deferring to an external script
  ExternalScript {
    /// Hash of the script
    other_script: ScriptHash,
    /// Additional data
    other_data: Data,
  }
  /// Protocol upgrade, lets users lock and unlock tokens between protocol versions
  GovNewCompat { upgrade_policy: PolicyId }
}

pub type ActiveParams {
  /// The ordered list of permitted collateral assets
  collateral_assets: List<AssetClass>,
  /// The numerators of the collateral weights
  weights: List<Int>,
  /// The shared denominator of the collateral weights
  denominator: Int,
  /// Minimum amount of the synthetic each created CDP must mint
  minimum_outstanding_synthetic: Int,
  /// 10 most recent interest rates with timestamps, global max rate with timestamp 0 is final element. Rates are in basis points
  interest_rates: List<(PosixTime, Int)>,
  /// Maximum proportion of the debt that can be collateralized by the ith token
  max_proportions: List<Int>,
  /// The % value, in terms of the synthetic, that a liquidator can claim from the CDP during a liquidation
  max_liquidation_return: Int,
  /// What % of the excess in a liquidation goes to the treasury
  treasury_liquidation_share: Int,
  /// What % of the repayed value in a redemption can the redeemer claim
  redemption_share: Int,
  /// What % discount users get on interest repayments when they use the protocol fee token (BTN)
  fee_token_discount: Int,
  /// 10 most recent interest rates with timestamps, global max rate with timestamp 0 is final element. Rates are in basis points
  staking_interest_rates: List<(PosixTime, Int)>,
}

pub type Params {
  LiveParams { params: ActiveParams }
  /// This transition happens if the price feed denominator is ever 0
  VoidedParams
}

pub type ParamAction {
  /// Adding a new collateral asset
  NewCollateral {
    /// Index of the new asset in the ordered list of collateral assets
    index: Int,
    /// The new asset to add
    collateral_asset: AssetClass,
    /// The weight numerator of the new asset
    weight_numerator: Int,
    /// The weight denominator of the new asset
    weight_denominator: Int,
    /// The maximum proportion of the new asset
    max_proportion: Int,
  }
  /// Updating the weight of an asset
  UpdateWeight {
    /// The index of the asset to update
    collateral_asset_idx: Int,
    /// The new weight numerator
    weight_numerator: Int,
    /// The new weight denominator
    weight_denominator: Int,
  }
  /// Adding a new interest rate
  UpdateInterest {
    /// The new interest rate
    interest_rate: Int,
  }
  /// Updating the minimum outstanding synthetic
  UpdateMinOutstanding {
    /// The new minimum outstanding synthetic
    min_outstanding: Int,
  }
  /// Updating the maximum proportions
  UpdateMaxProportions {
    /// The new maximum proportions
    max_proportions: List<Int>,
  }
  /// Updating the maximum liquidation return
  UpdateMaxLiquidationReturn {
    /// The new maximum liquidation return
    max_return: Int,
  }
  /// Updating the treasury liquidation share
  UpdateTreasuryLiquidationShare {
    /// The new treasury liquidation share
    share: Int,
  }
  /// Updating the redemption share
  UpdateRedemptionShare {
    /// The new redemption share
    share: Int,
  }
  /// Updating the fee token discount
  UpdateFeeTokenDiscount {
    /// The new fee token discount
    discount: Int,
  }
  /// Adding a new interest rate
  UpdateStakingInterest {
    /// The new interest rate
    interest_rate: Int,
  }
}

// Redeemers
/// The type of the CDP spending action
pub type SpendType {
  /// CDP Liquidations
  LiquidateCDP
  PartialLiquidateCDP { repay_amount: Int }
  LeftoversLiquidateCDP
  /// Repaying the debt of a CDP as an owner
  RepayCDP(CDPCredentialVerifier)
  /// Redeeming a CDP
  RedeemCDP
}

/// How the interest is being repayed
pub type FeeType {
  /// Pay the fee in terms of the synthetic asset
  FeeInSynthetic
  /// Pay the fee in the protocol fee token
  FeeInFeeToken {
    /// The index of the fee token in the price feed list
    fee_token_idx: Int,
  }
}

/// An action that spends a CDP output
pub type SpendAction {
  /// The action type
  spend_type: SpendType,
  /// Index of the params reference input in the ordered list of params (i.e., excluding other reference inputs)
  params_idx: Int,
  /// How the user is paying the fee
  fee_type: FeeType,
}

/// Redeemer for forwards compatibility
pub type CompatRedeemer {
  /// Locking future tokens and minting tokens for this protocol version
  CompatLock { oidx: Int }
  /// Unlocking future tokens and burning tokens from this protocol version
  CompatUnlock { soidx: Option<Int> }
}

/// Redeemer for the main script
pub type PolicyRedeemer {
  /// CDP actions
  SyntheticsMain {
    /// The list of actions that spend a CDP
    spends: List<SpendAction>,
    /// The list of creation actions. CDP creations are grouped by synthetic type in the same order as referenced param inputs
    creates: List<Int>,
  }
  CollectVoidedCDP { verifier: CDPCredentialVerifier }
  /// Treasury handling bad debt
  BadDebt {
    /// Leftover output index
    treasury_out_idx: Int,
  }
  Auxilliary
}

// Redeemer for the auxilliary script
pub type AuxilliaryRedeemer {
  /// Creation of new params
  ParamsMint {
    /// Index of created output
    oidx: Int,
  }
  /// Update of params
  ParamsUpdate {
    /// Index of updated output
    oidx: Int,
    /// Whether the spent gov UTxO comes before the spent params UTxO or not
    reverse_order: Bool,
  }
  ParamsVoid
  /// Creation of a governance action
  GovernanceIssue {
    /// Index of created governance action
    output_idx: Int,
  }
  /// Invoking of external governance script
  ExternalGovernance
  /// Spending from treasury
  TreasurySpend {
    /// Index of the expected created output
    expected_output_idx: Int,
    /// In the list of inputs spent at the CDP script, the index of the governance action input
    gov_inp_idx: Int,
    /// Whether the treasury inputs to spend are from fees
    inputs_from_fees: Bool,
  }
  /// Minting tokens from the treasury
  TreasuryMint {
    /// Index of the expected created output
    expected_output_idx: Int,
  }

  /// Creating debt for the treasury
  TreasuryCreateDebt {
    /// Index of the expected created output
    expected_output_idx: Int,
  }
  /// Redeeming from the treasury
  TreasuryRedemption {
    // If burning created debt fully, whether the lock token comes first in the burned value.
    // Set to None if not burning created debt fully
    lock_burned: Option<Bool>,
    /// Whether the treasury inputs to redeem are from fees
    inputs_from_fees: Bool,
  }
  TreasuryDelegate
  TreasuryGetRewards
  /// Compatibility with a different protocol version
  Compatibility { inner: CompatRedeemer }
  Staking(StakingRedeemer)
}

pub type StakingRedeemer {
  StakeSynthetics { staked_amount: Int }
  UnstakeSynthetics { verifier: CDPCredentialVerifier }
}

// Price feeds
/// Generic feed with data and extra information
pub type Feed<x, y> {
  /// Arbitrary data
  data: x,
  /// Extra information
  extra: y,
}

/// A price feed
pub type PriceFeed {
  /// Numerators of prices of collateral tokens in terms of the synthetic
  collateral_prices: List<Int>,
  /// The synthetic associated with the price feed
  synthetic: AssetName,
  /// The denominator of the prices
  denominator: Int,
  /// Validity interval of the price feed
  validity: ValidityRange,
}

/// Redeemer for the price feed script, a list of price feeds and signatures, in the same order as the synthetic parameter reference inputs
pub type PriceFeedRedeemer =
  List<Feed<PriceFeed, ByteArray>>
