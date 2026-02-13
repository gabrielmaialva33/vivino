import gleam/float
import gleam/int
import gleam/list
import gleeunit
import vivino/serial/parser
import vivino/signal/features
import vivino/signal/gpu
import vivino/signal/hdc

pub fn main() -> Nil {
  gleeunit.main()
}

// ============================================================
// Parser tests
// ============================================================

pub fn parse_csv_line_test() {
  let assert Ok(r) = parser.parse_reading("10.50,500,666.00,0.50")
  assert r.elapsed == 10.5
  assert r.raw == 500
  assert r.mv == 666.0
  assert r.deviation == 0.5
}

pub fn parse_integer_values_test() {
  let assert Ok(r) = parser.parse_reading("100,9959,669,2")
  assert r.elapsed == 100.0
  assert r.raw == 9959
  assert r.mv == 669.0
  assert r.deviation == 2.0
}

pub fn parse_negative_deviation_test() {
  let assert Ok(r) = parser.parse_reading("5.0,500,660.0,-6.5")
  assert r.deviation == -6.5
}

pub fn parse_invalid_line_test() {
  let assert Error(_) = parser.parse_reading("not,csv,data")
}

pub fn parse_empty_line_test() {
  let assert Error(_) = parser.parse_reading("")
}

pub fn parse_too_few_fields_test() {
  let assert Error(_) = parser.parse_reading("1.0,500")
}

pub fn parse_line_data_test() {
  let line = parser.parse_line("10.50,500,666.00,0.50")
  case line {
    parser.DataLine(r) -> { let assert True = r.mv == 666.0 }
    _ -> panic as "Expected DataLine"
  }
}

pub fn parse_line_stim_test() {
  let line = parser.parse_line("STIM,5.0,HABIT,3,PULSE,50ms")
  case line {
    parser.StimLine(s) -> { let assert True = s.protocol == "HABIT" }
    _ -> panic as "Expected StimLine"
  }
}

pub fn parse_line_meter_test() {
  let line = parser.parse_line("METER,5.23,1512.340,14bit,1.5123")
  case line {
    parser.MeterLine(m) -> {
      let assert True = m.elapsed == 5.23
      let assert True = m.mv == 1512.34
    }
    _ -> panic as "Expected MeterLine"
  }
}

pub fn parse_line_stats_test() {
  let line = parser.parse_line("--- STATS ---")
  case line {
    parser.StatsLine(_) -> Nil
    _ -> panic as "Expected StatsLine"
  }
}

pub fn parse_line_header_test() {
  let line = parser.parse_line("========= VIVINO =========")
  case line {
    parser.HeaderLine(_) -> Nil
    _ -> panic as "Expected HeaderLine"
  }
}

pub fn parse_readings_batch_test() {
  let text = "1.0,100,666.0,0.5\n2.0,101,667.0,1.5\nbad line\n3.0,102,668.0,2.5"
  let readings = parser.parse_readings(text)
  let assert True = list.length(readings) == 3
}

pub fn reading_to_json_test() {
  let r = parser.Reading(elapsed: 1.0, raw: 500, mv: 666.0, deviation: 0.5)
  let json = parser.reading_to_json(r)
  let assert True = json != ""
}

// ============================================================
// Feature extraction tests
// ============================================================

fn make_readings(deviations: List(Float)) -> List(parser.Reading) {
  list.index_map(deviations, fn(d, i) {
    parser.Reading(
      elapsed: { i |> int_to_float } *. 0.05,
      raw: 500,
      mv: 666.0 +. d,
      deviation: d,
    )
  })
}

fn int_to_float(i: Int) -> Float {
  case i {
    0 -> 0.0
    _ -> {
      let assert Ok(f) = float.parse(
        case i >= 0 {
          True -> {
            let s = int_to_string_simple(i)
            s <> ".0"
          }
          False -> {
            let s = int_to_string_simple(-1 * i)
            "-" <> s <> ".0"
          }
        },
      )
      f
    }
  }
}

fn int_to_string_simple(n: Int) -> String {
  // Use gleam/int.to_string via the import
  import_int_to_string(n)
}

@external(erlang, "erlang", "integer_to_binary")
fn import_int_to_string(n: Int) -> String

/// Flat signal should produce near-zero features
pub fn features_flat_signal_test() {
  let readings = make_readings(list.repeat(0.0, 20))
  let f = features.extract(readings)
  let assert True = f.mean == 0.0
  let assert True = f.std == 0.0
  let assert True = f.range == 0.0
  let assert True = f.dvdt_max == 0.0
}

/// Ramp signal should have positive slope
pub fn features_ramp_signal_test() {
  let devs =
    int.range(from: 0, to: 20, with: [], run: fn(acc, i) {
      [int_to_float(i) *. 2.0, ..acc]
    })
    |> list.reverse
  let readings = make_readings(devs)
  let f = features.extract(readings)
  // Slope should be positive (increasing signal)
  let assert True = f.slope >. 0.0
  // Range should be about 38 (0 to 38)
  let assert True = f.range >. 30.0
  // Mean should be around 19
  let assert True = f.mean >. 10.0
}

/// Spike should have high dvdt_max
pub fn features_spike_detection_test() {
  let base = list.repeat(0.0, 9)
  let spike = [50.0]
  let after = list.repeat(0.0, 10)
  let readings = make_readings(list.flatten([base, spike, after]))
  let f = features.extract(readings)
  // dvdt_max should be large (50mV jump at 20Hz = 1000 mV/s)
  let assert True = f.dvdt_max >. 500.0
  // Peak count should be >= 1
  let assert True = f.peak_count >=. 1.0
}

/// Feature count should be 27 (19 time-domain + 8 MFCC)
pub fn features_dimension_test() {
  // Use varying signal to avoid numerical edge cases
  let devs = [
    0.0, 1.0, -1.0, 2.0, -2.0, 3.0, -3.0, 4.0, -4.0, 5.0, -5.0, 4.0, -4.0,
    3.0, -3.0, 2.0, -2.0, 1.0, -1.0, 0.0,
  ]
  let readings = make_readings(devs)
  let f = features.extract(readings)
  let assert True = list.length(f.mfcc) == 8
}

/// Classify state should return valid string
pub fn features_classify_state_test() {
  let readings = make_readings(list.repeat(0.0, 20))
  let f = features.extract(readings)
  let state = features.classify_state(f)
  // Flat signal should be RESTING
  let assert True =
    state == "RESTING" || state == "CALM"
}

// ============================================================
// GPU classifier tests
// ============================================================

pub fn gpu_init_test() {
  let assert Ok(_) = gpu.init()
}

pub fn gpu_classify_resting_test() {
  let assert Ok(g) = gpu.init()
  let readings = make_readings(list.repeat(0.0, 20))
  let f = features.extract(readings)
  let #(state, sims) = gpu.classify(g, f)
  // Should return a valid state
  let assert True = state != "???"
  // Should have 6 state probabilities
  let assert True = list.length(sims) == 6
  // Probabilities should sum to ~1.0
  let sum = list.fold(sims, 0.0, fn(acc, s) { acc +. s.1 })
  let assert True = sum >. 0.99 && sum <. 1.01
}

pub fn gpu_classify_stimulus_test() {
  let assert Ok(g) = gpu.init()
  // Create a high-energy spike signal
  let devs = [
    0.0, 0.0, 0.0, 5.0, 20.0, 50.0, 80.0, 60.0, 30.0, 10.0, 0.0, 0.0, 0.0,
    0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0,
  ]
  let readings = make_readings(devs)
  let f = features.extract(readings)
  let #(state, _sims) = gpu.classify(g, f)
  // High-energy signal should NOT be classified as RESTING
  let assert True = state != "RESTING"
}

// ============================================================
// HDC classifier tests
// ============================================================

pub fn hdc_init_test() {
  let _memory = hdc.init()
  // Should initialize without crashing
  Nil
}

pub fn hdc_encode_test() {
  let memory = hdc.init()
  let readings = make_readings(list.repeat(0.0, 20))
  let f = features.extract(readings)
  let _hv = hdc.encode(memory, f)
  // Should produce a hypervector without crashing
  Nil
}

pub fn hdc_classify_test() {
  let memory = hdc.init()
  let readings = make_readings(list.repeat(0.0, 20))
  let f = features.extract(readings)
  let hv = hdc.encode(memory, f)
  let state = hdc.classify(memory, hv)
  // Should return a valid state
  let state_str = hdc.state_to_string(state)
  let assert True = state_str != ""
}

pub fn hdc_similarities_count_test() {
  let memory = hdc.init()
  let readings = make_readings(list.repeat(0.0, 20))
  let f = features.extract(readings)
  let hv = hdc.encode(memory, f)
  let sims = hdc.similarities(memory, hv)
  // Should have 5 state similarities
  let assert True = list.length(sims) == 5
}

pub fn hdc_state_to_string_test() {
  let assert True = hdc.state_to_string(hdc.Resting) == "RESTING"
  let assert True = hdc.state_to_string(hdc.Calm) == "CALM"
  let assert True = hdc.state_to_string(hdc.Active) == "ACTIVE"
  let assert True = hdc.state_to_string(hdc.Stimulus) == "STIMULUS"
  let assert True = hdc.state_to_string(hdc.Stress) == "STRESS"
  let assert True = hdc.state_to_string(hdc.Unknown) == "???"
}
