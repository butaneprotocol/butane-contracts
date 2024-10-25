use butane/types

validator {
  fn always_true(_d, _r, _ctx) {
    True
  }
}

validator {
  fn types(_r: types.ConstraintCredential, _ctx) {
    True
  }
}
