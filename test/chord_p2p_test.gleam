import gleeunit
import gleeunit/should
import gleam/list

pub fn main() {
  gleeunit.main()
}

// Test basic arithmetic to ensure test framework works
pub fn basic_test() {
  let result = 2 + 2
  result |> should.equal(4)
}

// Test list operations
pub fn list_test() {
  let numbers = [1, 2, 3, 4, 5]
  let length = list.length(numbers)
  length |> should.equal(5)
}