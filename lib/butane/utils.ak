use aiken/builtin
use aiken/bytearray
use aiken/dict.{Dict}
use aiken/interval.{Finite, Interval, IntervalBound}
use aiken/list
use aiken/math
use aiken/math/rational.{Rational}
use aiken/pairs
use aiken/time.{PosixTime}
use aiken/transaction.{InlineDatum, Input, Output, OutputReference}
use aiken/transaction/credential.{
  Credential, Inline, ScriptCredential, StakeCredential,
}
use aiken/transaction/value.{AssetName, PolicyId, Value, quantity_of}
use butane/types
use butane/unsafe

pub fn lcm(a: Int, b: Int) {
  a * b / math.gcd(a, b)
}

/// Checks whether a given interval is a subset of the interval
pub fn contains_interval(self: Interval<Int>, interval: Interval<Int>) -> Bool {
  interval.intersection(self, interval) == interval
}

/// For a finite interval, returns the range of the interval
pub fn finite_interval_range(interval: Interval<Int>) -> Int {
  expect Interval {
    lower_bound: IntervalBound { bound_type: Finite(lb), .. },
    upper_bound: IntervalBound { bound_type: Finite(ub), .. },
  } = interval
  ub - lb
}

pub fn check_price_feed_validity(
  pf_validity: Interval<PosixTime>,
  tx_validity: Interval<PosixTime>,
) {
  and {
    (finite_interval_range(pf_validity) < types.milliseconds_in_day)?,
    contains_interval(pf_validity, tx_validity)?,
  }
}

pub fn until_input_from(cred: Credential, inputs: List<Input>) {
  if builtin.head_list(inputs).output.address.payment_credential == cred {
    inputs
  } else {
    until_input_from(cred, builtin.tail_list(inputs))
  }
}

pub fn gov_has_lock_token(gov_inp: Input, own_hash: types.ScriptHash) {
  gov_inp.output.value
    |> value.tokens(own_hash)
    |> dict.has_key(types.gov_lock_token_name)
}

/// Ensures that nothing is minted at the given policy
pub fn mints_nothing_here(v: Value, p: PolicyId) {
  builtin.null_list(value.tokens(v, p) |> dict.to_pairs)
}

/// Ensures that the only token minted at this policy is the given asset name with the given amount
pub fn only_mints_this(v: Value, p: PolicyId, n: AssetName, a: Int) {
  ( value.tokens(v, p) |> dict.to_pairs ) == [Pair(n, a)]
}

pub fn until_zero(remaining: Int, acc: a, with: fn(a) -> a) -> a {
  if remaining == 0 {
    acc
  } else {
    until_zero(remaining - 1, with(acc), with)
  }
}

pub fn compare_asset_classes(
  a: types.AssetClass,
  b: types.AssetClass,
) -> Ordering {
  when bytearray.compare(a.policy_id, b.policy_id) is {
    Equal -> bytearray.compare(a.asset_name, b.asset_name)
    x -> x
  }
}

pub fn list_insert_at(l: List<a>, idx: Int, el: a) -> List<a> {
  if l == [] {
    [el]
  } else if idx == 0 {
    [el, ..l]
  } else {
    [builtin.head_list(l), ..list_insert_at(builtin.tail_list(l), idx - 1, el)]
  }
}

test list_insert_at_1() {
  let l =
    [1, 2, 3]
  let l2 = list_insert_at(l, 1, 4)
  l2 == [1, 4, 2, 3]
}

test list_insert_at_2() {
  let l =
    [1, 2, 3]
  let l2 = list_insert_at(l, 0, 4)
  l2 == [4, 1, 2, 3]
}

test list_insert_at_3() {
  let l =
    [1, 2, 3]
  let l2 = list_insert_at(l, 3, 4)
  l2 == [1, 2, 3, 4]
}

test list_insert_at_4() {
  let l =
    [1, 2, 3]
  let l2 = list_insert_at(l, 4, 4)
  l2 == [1, 2, 3, 4]
}

pub fn sorted_list_is_unique(l: List<a>) -> Bool {
  when l is {
    [x, y, ..xs] ->
      if x == y {
        False
      } else {
        sorted_list_is_unique([y, ..xs])
      }
    _ -> True
  }
}

test sorted_list_is_unique_1() {
  let l =
    [1, 2, 3]
  sorted_list_is_unique(l)
}

test sorted_list_is_unique_2() {
  let l =
    [1, 2, 2, 3]
  !sorted_list_is_unique(l)
}

// Returns the fee percentage in basis points
pub fn calculate_fee_percent(
  interest_rates: List<(PosixTime, Int)>,
  cdp_start_time: PosixTime,
  close_time: PosixTime,
) -> Int {
  do_calculate_fee_percent(0, close_time, interest_rates, cdp_start_time)
}

pub fn do_calculate_fee_percent(
  acc_percent: Int,
  prev_time: PosixTime,
  interest_rates: List<(PosixTime, Int)>,
  cdp_start_time: PosixTime,
) {
  let (time_neg, rate) = builtin.head_list(interest_rates)
  let time = -time_neg
  if time < cdp_start_time {
    let time_diff = prev_time - cdp_start_time
    let new_acc = acc_percent + rate * time_diff
    new_acc
  } else {
    let time_diff = prev_time - time
    let new_acc = acc_percent + rate * time_diff
    do_calculate_fee_percent(
      new_acc,
      time,
      builtin.tail_list(interest_rates),
      cdp_start_time,
    )
  }
}

// Returns the fee percentage in basis points
pub fn calculate_earnings_percent(
  interest_rates: List<(PosixTime, Int)>,
  staking_start_time: PosixTime,
  staking_end_time: PosixTime,
) -> Int {
  do_calculate_earnings_percent(
    0,
    staking_end_time,
    interest_rates,
    staking_start_time,
  )
}

pub fn do_calculate_earnings_percent(
  acc_percent: Int,
  prev_time: PosixTime,
  interest_rates: List<(PosixTime, Int)>,
  staking_start_time: PosixTime,
) {
  when interest_rates is {
    [(time_neg, rate), ..xs] -> {
      let time = -time_neg
      if time < staking_start_time {
        let time_diff = prev_time - staking_start_time
        let new_acc = acc_percent + rate * time_diff
        new_acc
      } else {
        let time_diff = prev_time - time
        let new_acc = acc_percent + rate * time_diff
        do_calculate_earnings_percent(new_acc, time, xs, staking_start_time)
      }
    }
    _ -> acc_percent
  }
}

pub fn fake_to_real_out(in: types.FakeOutput) -> Output {
  let types.FakeOutput { value, address, reference_script, datum } = in
  Output {
    address,
    reference_script,
    datum,
    value: {
      let (fst, snd), acc <- list.foldl(value, value.zero())
      let (fst2, snd2), acc <- list.foldl(snd, acc)
      value.add(acc, fst, fst2, snd2)
    },
  }
}

pub fn get_state_delta(
  synthetic_name: AssetName,
  repaid_amount: Int,
  fee_type: types.FeeType,
  fee_in_synthetic: Int,
  staking_interest_rates: List<(PosixTime, Int)>,
  cdp_start_time: PosixTime,
  cdp_close_time: PosixTime,
  fee_token_discount: Int,
  treasury_share: Value,
  p_list: List<Int>,
  p_denom: Int,
  collateral_assets: List<types.AssetClass>,
  fee_token: types.AssetClass,
  g: fn(Dict<AssetName, Int>, Int, Value) -> a,
) {
  when fee_type is {
    types.FeeInSynthetic ->
      g(
        dict.new()
          |> dict.insert(synthetic_name, -repaid_amount - fee_in_synthetic),
        0,
        treasury_share,
      )
    types.FeeInFeeToken { fee_token_idx } -> {
      // The theoretical maximum staking rewards that could be earned if the repaid amount was staked for the entire duration
      // The amount of rewards given in staking should never be higher than the required interest to be paid
      let max_staking_rewards =
        calculate_earnings_percent(
          interest_rates: staking_interest_rates,
          staking_start_time: cdp_start_time,
          staking_end_time: cdp_close_time,
        ) * repaid_amount / types.bp_precision / types.milliseconds_in_year
      let price = unsafe.list_at(p_list, fee_token_idx)
      expect unsafe.list_at(collateral_assets, fee_token_idx) == fee_token
      let expected_fee =
        math.max(
          0,
          price * ( fee_in_synthetic - max_staking_rewards ) * (
            types.bp_precision - fee_token_discount
          ) / types.bp_precision / p_denom,
        )
      g(
        dict.new()
          |> dict.insert(synthetic_name, -(repaid_amount + max_staking_rewards)),
        -expected_fee,
        treasury_share,
      )
    }
  }
}

pub fn get_treasury_share(
  claimed_value: Value,
  treasury_share_percent: Int,
  cr: Rational,
) {
  if rational.compare(cr, rational.from_int(1)) == Less {
    value.zero()
  } else {
    let scale_num = rational.denominator(cr)
    let scale_denom = rational.numerator(cr)
    let p, n, amount, v <- value.reduce(claimed_value, value.zero())
    let excess_amount = amount - amount * scale_num / scale_denom
    if excess_amount > 0 {
      value.add(
        v,
        p,
        n,
        excess_amount * treasury_share_percent / types.bp_precision,
      )
    } else {
      v
    }
  }
}

// Checks whether a given list of fractions with the same denominator could all be reduced with a smaller denominator
pub fn is_minimal_denom(nums: List<Int>, denom: Int) -> Bool {
  list.foldl(nums, denom, fn(n, acc) { math.gcd(math.gcd(n, denom), acc) }) == 1
}

pub fn is_reserved_asset(asset: AssetName) -> Bool {
  or {
    (asset == types.cdp_lock_token_name)?,
    (asset == types.gov_lock_token_name)?,
    (asset == types.staking_lock_token_name)?,
    (bytearray.take(asset, types.params_prefix_length) == types.params_prefix)?,
    (bytearray.take(asset, types.debt_prefix_length) == types.debt_prefix)?,
  }
}

pub fn authorization_check(
  fcredential: types.CDPCredential,
  this_oref: OutputReference,
  verifier: types.CDPCredentialVerifier,
  extra_signatories: List<types.PubKeyHash>,
  inputs: List<Input>,
  withdrawals: Pairs<StakeCredential, Int>,
  valid_from: Int,
  valid_to: Int,
) {
  when verifier is {
    types.AuthorizingDirectly(cv2) ->
      when cv2 is {
        types.AuthorizedWithExtraSigs -> {
          expect types.AuthorizeWithPubKey(hash, _) = fcredential
          extra_signatories |> list.has(hash)
        }
        types.AuthorizedWithInputsOref(oref) -> {
          expect types.AuthorizeWithConstraint(types.MustSpendToken(asset)) =
            fcredential
          let inp =
            unsafe.unsome(
              inputs |> list.find(fn(inp) { inp.output_reference == oref }),
            )
          quantity_of(inp.output.value, asset.policy_id, asset.asset_name) >= 1
        }
        types.AuthorizedWithWithdrawal -> {
          expect types.AuthorizeWithConstraint(types.MustWithdrawFrom(
            stake_cred,
          )) = fcredential
          withdrawals |> pairs.has_key(stake_cred)
        }
      }
    types.AuthorizingOtherWithSignature { other, sub_verifier, signature } -> {
      expect types.AuthorizeWithPubKey(_, key) = fcredential
      let types.ConstraintCredential { utxo, interval, constraint } = other
      expect Interval {
        lower_bound: IntervalBound { bound_type: Finite(interval_lb), .. },
        upper_bound: IntervalBound { bound_type: Finite(interval_ub), .. },
      } = interval
      and {
        // This utxo is the utxo being spent
        (utxo == this_oref)?,
        (interval_lb <= valid_from)?,
        (interval_ub >= valid_to)?,
        // Validate signature of other
        builtin.verify_ed25519_signature(
          key,
          builtin.serialise_data(other),
          signature,
        )?,
        // Also validate other
        authorization_check(
          fcredential: types.AuthorizeWithConstraint(constraint),
          this_oref: this_oref,
          verifier: types.AuthorizingDirectly(sub_verifier),
          extra_signatories: extra_signatories,
          inputs: inputs,
          withdrawals: withdrawals,
          valid_from: valid_from,
          valid_to: valid_to,
        )?,
      }
    }
  }
}

pub fn not_withdrawing_from(
  withdrawals: Pairs<StakeCredential, Int>,
  cred: StakeCredential,
) -> Bool {
  !pairs.has_key(withdrawals, cred)
}

pub fn withdraws_zero(
  withdrawals: Pairs<StakeCredential, Int>,
  cred: StakeCredential,
) -> Bool {
  pairs.get_first(withdrawals, cred) == Some(0)
}

pub fn to_monodatum(raw: Data) -> types.MonoDatum {
  expect parsed: types.MonoDatum = raw
  parsed
}

pub fn to_pricefeedredeemer(raw: Data) -> types.PriceFeedRedeemer {
  expect parsed: types.PriceFeedRedeemer = raw
  parsed
}

pub fn params_from_refs(reference_inputs: List<Input>, own_hash: ByteArray) {
  let ret_list, ref_input <- list.reduce(reference_inputs, [])
  let Input {
    output: Output { datum: ref_input_data, value: ref_input_value, .. },
    ..
  } = ref_input
  // We use invariant that any params tokens minted are the only Butane tokens in that utxo
  when value.tokens(ref_input_value, own_hash) |> dict.to_pairs is {
    [Pair(k, _)] ->
      if bytearray.take(k, types.params_prefix_length) == types.params_prefix {
        let params_synthetic_name =
          bytearray.drop(k, types.params_prefix_length)
        expect InlineDatum(params_data) = ref_input_data
        expect types.ParamsWrapper(params_datum) = to_monodatum(params_data)
        [
          types.ParamsData {
            params: params_datum,
            synthetic: params_synthetic_name,
          },
          ..ret_list
        ]
      } else {
        ret_list
      }
    _ -> ret_list
  }
}

pub fn stake_cred_from_hash(hash: ByteArray) {
  Inline(ScriptCredential(hash))
}

pub fn find_input_with_credential(
  inputs: List<Input>,
  credential: Credential,
) -> Option<Input> {
  list.find(
    inputs,
    fn(i: Input) { i.output.address.payment_credential == credential },
  )
}
