use aiken/builtin

pub fn list_at(list: List<a>, i: Int) {
  if i == 0 {
    builtin.head_list(list)
  } else {
    list_at(builtin.tail_list(list), i - 1)
  }
}

pub fn unsome(x: Option<a>) -> a {
  expect Some(inner) = x
  inner
}
