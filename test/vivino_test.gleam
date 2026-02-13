import gleeunit
import vivino/serial/parser

pub fn main() -> Nil {
  gleeunit.main()
}

pub fn parse_csv_line_test() {
  let assert Ok(r) = parser.parse_reading("10.50,500,666.00,0.50")
  assert r.elapsed == 10.5
  assert r.raw == 500
  assert r.mv == 666.0
  assert r.deviation == 0.5
}

pub fn parse_invalid_line_test() {
  let assert Error(_) = parser.parse_reading("not,csv,data")
}
