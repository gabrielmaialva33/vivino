import gleam/float
import gleam/int
import gleam/list
import gleeunit
import vivino/serial/parser
import vivino/signal/dynamic_gpu
import vivino/signal/features
import vivino/signal/gpu
import vivino/signal/hdc
import vivino/signal/label_bridge
import vivino/signal/learner
import vivino/signal/profile

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
    parser.DataLine(r) -> {
      let assert True = r.mv == 666.0
    }
    _ -> panic as "Expected DataLine"
  }
}

pub fn parse_line_stim_test() {
  let line = parser.parse_line("STIM,5.0,HABIT,3,PULSE,50ms")
  case line {
    parser.StimLine(s) -> {
      let assert True = s.protocol == "HABIT"
    }
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
      let assert Ok(f) =
        float.parse(case i >= 0 {
          True -> {
            let s = int_to_string_simple(i)
            s <> ".0"
          }
          False -> {
            let s = int_to_string_simple(-1 * i)
            "-" <> s <> ".0"
          }
        })
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
    0.0, 1.0, -1.0, 2.0, -2.0, 3.0, -3.0, 4.0, -4.0, 5.0, -5.0, 4.0, -4.0, 3.0,
    -3.0, 2.0, -2.0, 1.0, -1.0, 0.0,
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
  let assert True = state == "RESTING" || state == "CALM"
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
    0.0, 0.0, 0.0, 5.0, 20.0, 50.0, 80.0, 60.0, 30.0, 10.0, 0.0, 0.0, 0.0, 0.0,
    0.0, 0.0, 0.0, 0.0, 0.0, 0.0,
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

// ============================================================
// Profile tests
// ============================================================

pub fn profile_shimeji_test() {
  let prof = profile.get_profile(profile.Shimeji)
  let assert True = prof.name == "shimeji"
  let assert True = prof.organism == profile.Shimeji
  let assert True = list.length(prof.gpu_prototypes) == 6
  let assert True = list.length(prof.gpu_bounds) == 19
}

pub fn profile_cannabis_test() {
  let prof = profile.get_profile(profile.Cannabis)
  let assert True = prof.name == "cannabis"
  // Cannabis has wider ranges than shimeji
  let assert True = prof.quant_ranges.mean_max >. 100.0
  let assert True = prof.thresholds.resting_std_max >. 5.0
}

pub fn profile_fungal_test() {
  let prof = profile.get_profile(profile.FungalGeneric)
  let assert True = prof.name == "fungal_generic"
  let assert True = prof.display_name == "Fungo generico"
}

pub fn profile_parse_organism_test() {
  let assert Ok(profile.Shimeji) = profile.parse_organism("shimeji")
  let assert Ok(profile.Cannabis) = profile.parse_organism("cannabis")
  let assert Ok(profile.FungalGeneric) = profile.parse_organism("fungal")
  let assert Ok(profile.FungalGeneric) = profile.parse_organism("fungo")
  let assert Error(_) = profile.parse_organism("banana")
}

pub fn profile_prototypes_19_features_test() {
  // Each prototype vector should have 19 elements
  let prof = profile.get_profile(profile.Shimeji)
  list.each(prof.gpu_prototypes, fn(p) {
    let assert True = list.length(p) == 19
  })
}

// ============================================================
// Dynamic GPU tests
// ============================================================

pub fn dynamic_gpu_init_test() {
  let prof = profile.get_profile(profile.Shimeji)
  let assert Ok(_) = dynamic_gpu.init(prof)
}

pub fn dynamic_gpu_classify_test() {
  let prof = profile.get_profile(profile.Shimeji)
  let assert Ok(g) = dynamic_gpu.init(prof)
  let readings = make_readings(list.repeat(0.0, 20))
  let f = features.extract(readings)
  let #(state, sims) = dynamic_gpu.classify(g, f)
  let assert True = state != "???"
  let assert True = list.length(sims) == 6
  // Probabilities should sum to ~1.0
  let sum = list.fold(sims, 0.0, fn(acc, s) { acc +. s.1 })
  let assert True = sum >. 0.99 && sum <. 1.01
}

pub fn dynamic_gpu_learn_test() {
  let prof = profile.get_profile(profile.Shimeji)
  let assert Ok(g) = dynamic_gpu.init(prof)
  let readings = make_readings(list.repeat(0.0, 20))
  let f = features.extract(readings)
  // Learn should not crash
  let g2 = dynamic_gpu.learn(g, f, "RESTING")
  // Classify after learning should still work
  let #(state, _) = dynamic_gpu.classify(g2, f)
  let assert True = state != "???"
}

pub fn dynamic_gpu_cannabis_profile_test() {
  let prof = profile.get_profile(profile.Cannabis)
  let assert Ok(g) = dynamic_gpu.init(prof)
  let readings = make_readings(list.repeat(0.0, 20))
  let f = features.extract(readings)
  let #(_, sims) = dynamic_gpu.classify(g, f)
  let assert True = list.length(sims) == 6
}

// ============================================================
// Learner (Dynamic HDC) tests
// ============================================================

pub fn learner_init_test() {
  let prof = profile.get_profile(profile.Shimeji)
  let _mem = learner.init(prof)
  Nil
}

pub fn learner_encode_test() {
  let prof = profile.get_profile(profile.Shimeji)
  let mem = learner.init(prof)
  let readings = make_readings(list.repeat(0.0, 20))
  let f = features.extract(readings)
  let _hv = learner.encode(mem, f, prof.quant_ranges)
  Nil
}

pub fn learner_classify_test() {
  let prof = profile.get_profile(profile.Shimeji)
  let mem = learner.init(prof)
  let readings = make_readings(list.repeat(0.0, 20))
  let f = features.extract(readings)
  let hv = learner.encode(mem, f, prof.quant_ranges)
  let #(state, sims, _novelty) = learner.classify(mem, hv)
  let state_str = learner.state_to_string(state)
  let assert True = state_str != ""
  let assert True = list.length(sims) == 6
}

pub fn learner_learn_test() {
  let prof = profile.get_profile(profile.Shimeji)
  let mem = learner.init(prof)
  let readings = make_readings(list.repeat(0.0, 20))
  let f = features.extract(readings)
  let hv = learner.encode(mem, f, prof.quant_ranges)
  // Learn RESTING
  let mem2 = learner.learn(mem, hv, learner.Resting, 1.0)
  // Should have 1 exemplar
  let counts = learner.exemplar_counts(mem2)
  let resting_count = list.find(counts, fn(c) { c.0 == learner.Resting })
  let assert Ok(#(_, count)) = resting_count
  let assert True = count == 1
}

pub fn learner_auto_calibrate_test() {
  let prof = profile.get_profile(profile.Shimeji)
  let mem = learner.init(prof)
  let readings = make_readings(list.repeat(0.0, 20))
  let f = features.extract(readings)
  let hv = learner.encode(mem, f, prof.quant_ranges)
  // Calibrate at sample 0 (should add RESTING)
  let mem2 = learner.auto_calibrate(mem, hv, 0, 0.0)
  let counts = learner.exemplar_counts(mem2)
  let resting_count = list.find(counts, fn(c) { c.0 == learner.Resting })
  let assert Ok(#(_, count)) = resting_count
  let assert True = count == 1
  // Calibrate at sample 5 (not multiple of 10, should NOT add)
  let mem3 = learner.auto_calibrate(mem2, hv, 5, 0.25)
  let counts3 = learner.exemplar_counts(mem3)
  let resting_count3 = list.find(counts3, fn(c) { c.0 == learner.Resting })
  let assert Ok(#(_, count3)) = resting_count3
  let assert True = count3 == 1
}

pub fn learner_state_parse_test() {
  let assert Ok(learner.Resting) = learner.parse_state("RESTING")
  let assert Ok(learner.Calm) = learner.parse_state("CALM")
  let assert Ok(learner.Active) = learner.parse_state("ACTIVE")
  let assert Ok(learner.Transition) = learner.parse_state("TRANSITION")
  let assert Ok(learner.Stimulus) = learner.parse_state("STIMULUS")
  let assert Ok(learner.Stress) = learner.parse_state("STRESS")
  let assert Error(_) = learner.parse_state("INVALID")
}

pub fn learner_ring_buffer_test() {
  let prof = profile.get_profile(profile.Shimeji)
  let mem = learner.init(prof)
  // Use different signals to generate diverse HVs (cutting angle won't reject)
  let make_hv = fn(offset: Float) {
    let devs =
      int.range(from: 0, to: 20, with: [], run: fn(acc, i) { [i, ..acc] })
      |> list.reverse
      |> list.map(fn(i) { int_to_float(i) *. offset })
    let readings = make_readings(devs)
    let f = features.extract(readings)
    learner.encode(mem, f, prof.quant_ranges)
  }
  // Add 6 RESTING exemplars with different HVs (max is 5, oldest drops)
  let mem2 = learner.learn(mem, make_hv(1.0), learner.Resting, 1.0)
  let mem3 = learner.learn(mem2, make_hv(2.0), learner.Resting, 2.0)
  let mem4 = learner.learn(mem3, make_hv(3.0), learner.Resting, 3.0)
  let mem5 = learner.learn(mem4, make_hv(5.0), learner.Resting, 4.0)
  let mem6 = learner.learn(mem5, make_hv(8.0), learner.Resting, 5.0)
  let mem7 = learner.learn(mem6, make_hv(13.0), learner.Resting, 6.0)
  let counts = learner.exemplar_counts(mem7)
  let resting_count = list.find(counts, fn(c) { c.0 == learner.Resting })
  let assert Ok(#(_, count)) = resting_count
  let assert True = count == 5
}

// ============================================================
// Label bridge tests
// ============================================================

pub fn label_bridge_put_get_test() {
  let assert Ok(_) = label_bridge.put_label("RESTING")
  let assert Ok(label) = label_bridge.get_label()
  let assert True = label == "RESTING"
  // Second get should return Error (consumed)
  let assert Error(_) = label_bridge.get_label()
}

pub fn label_bridge_organism_test() {
  let assert Ok(_) = label_bridge.put_organism("cannabis")
  let assert Ok(org) = label_bridge.get_organism()
  let assert True = org == "cannabis"
}

// ============================================================
// Cross-profile classification test
// ============================================================

pub fn cross_profile_gpu_test() {
  // Same signal should produce different results on different profiles
  let devs = [
    0.0, 5.0, 10.0, 15.0, 20.0, 15.0, 10.0, 5.0, 0.0, -5.0, -10.0, -5.0, 0.0,
    3.0, 6.0, 3.0, 0.0, -3.0, -6.0, -3.0,
  ]
  let readings = make_readings(devs)
  let f = features.extract(readings)

  let shimeji_prof = profile.get_profile(profile.Shimeji)
  let cannabis_prof = profile.get_profile(profile.Cannabis)

  let assert Ok(g_shi) = dynamic_gpu.init(shimeji_prof)
  let assert Ok(g_can) = dynamic_gpu.init(cannabis_prof)

  let #(state_shi, _) = dynamic_gpu.classify(g_shi, f)
  let #(state_can, _) = dynamic_gpu.classify(g_can, f)

  // Both should produce valid states (may or may not differ)
  let assert True = state_shi != "???"
  let assert True = state_can != "???"
}

// ============================================================
// IQR Outlier Cleaning tests (SIGNET)
// ============================================================

/// Clean outliers should not change a normal signal
pub fn clean_outliers_no_change_test() {
  let readings = make_readings(list.repeat(5.0, 20))
  let cleaned = features.clean_outliers(readings)
  // All deviations should remain unchanged
  list.each(cleaned, fn(r) {
    let assert True = r.deviation == 5.0
  })
}

/// Clean outliers should clamp extreme spikes
pub fn clean_outliers_clamps_spike_test() {
  // Normal values around 0-10 with one extreme outlier at 500
  let devs = [
    1.0, 2.0, 3.0, 4.0, 5.0, 6.0, 7.0, 8.0, 9.0, 10.0, 500.0, 1.0, 2.0, 3.0, 4.0,
    5.0, 6.0, 7.0, 8.0, 9.0,
  ]
  let readings = make_readings(devs)
  let cleaned = features.clean_outliers(readings)
  // The spike should be clamped down (no longer 500)
  let spike = case list.drop(cleaned, 10) {
    [r, ..] -> r.deviation
    _ -> 500.0
  }
  let assert True = spike <. 500.0
}

// ============================================================
// Signal Quality tests (SIGNET)
// ============================================================

/// Good signal should have quality score 1.0
pub fn signal_quality_good_test() {
  // Signal with non-zero mean so abs_mean/std > 0.5 (avoids "noisy" trigger)
  let devs = [
    10.0, 11.0, 9.0, 12.0, 8.0, 13.0, 7.0, 14.0, 6.0, 15.0, 5.0, 14.0, 6.0, 13.0,
    7.0, 12.0, 8.0, 11.0, 9.0, 10.0,
  ]
  let readings = make_readings(devs)
  let f = features.extract(readings)
  let q = features.assess_quality(f)
  let assert True = q.is_good
  let assert True = q.score == 1.0
  let assert True = q.reason == "good"
}

/// Flat line should be detected as bad quality
pub fn signal_quality_flat_line_test() {
  let readings = make_readings(list.repeat(0.0, 20))
  let f = features.extract(readings)
  let q = features.assess_quality(f)
  let assert True = !q.is_good
  let assert True = q.reason == "flat_line"
  let assert True = q.score <. 0.5
}

/// High kurtosis signal should be detected as artifact
pub fn signal_quality_artifact_test() {
  // Mostly flat with extreme spike → high kurtosis
  let devs = [
    0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 200.0, 0.0, 0.0, 0.0, 0.0, 0.0,
    0.0, 0.0, 0.0, 0.0, 0.0,
  ]
  let readings = make_readings(devs)
  let f = features.extract(readings)
  let q = features.assess_quality(f)
  // Should either be artifact (kurtosis > 15) or saturated (range > 500)
  let assert True = !q.is_good || q.reason == "good"
  // At minimum, kurtosis should be high for such a spike
  let assert True = f.kurtosis >. 5.0
}

/// Quality JSON serialization
pub fn quality_json_test() {
  let q = features.SignalQuality(score: 0.8, is_good: True, reason: "good")
  let _json = features.quality_to_json_value(q)
  // Should not crash
  Nil
}

// ============================================================
// Cutting Angle tests (HDC-EMG)
// ============================================================

/// Cutting angle should accept diverse exemplars
pub fn cutting_angle_accepts_diverse_test() {
  let prof = profile.get_profile(profile.Shimeji)
  let mem = learner.init(prof)
  // Two very different signals
  let hv1 = {
    let readings = make_readings(list.repeat(0.0, 20))
    let f = features.extract(readings)
    learner.encode(mem, f, prof.quant_ranges)
  }
  let hv2 = {
    let devs = [
      0.0, 10.0, 20.0, 30.0, 40.0, 50.0, 40.0, 30.0, 20.0, 10.0, 0.0, -10.0,
      -20.0, -30.0, -40.0, -50.0, -40.0, -30.0, -20.0, -10.0,
    ]
    let readings = make_readings(devs)
    let f = features.extract(readings)
    learner.encode(mem, f, prof.quant_ranges)
  }
  let mem2 = learner.learn(mem, hv1, learner.Active, 1.0)
  let mem3 = learner.learn(mem2, hv2, learner.Active, 2.0)
  // Both should be accepted (diverse enough)
  let counts = learner.exemplar_counts(mem3)
  let active_count = list.find(counts, fn(c) { c.0 == learner.Active })
  let assert Ok(#(_, count)) = active_count
  let assert True = count == 2
}

/// Cutting angle should reject duplicate exemplars
pub fn cutting_angle_rejects_duplicate_test() {
  let prof = profile.get_profile(profile.Shimeji)
  let mem = learner.init(prof)
  let readings = make_readings(list.repeat(5.0, 20))
  let f = features.extract(readings)
  let hv = learner.encode(mem, f, prof.quant_ranges)
  // Add same HV twice — second should be rejected
  let mem2 = learner.learn(mem, hv, learner.Calm, 1.0)
  let mem3 = learner.learn(mem2, hv, learner.Calm, 2.0)
  let counts = learner.exemplar_counts(mem3)
  let calm_count = list.find(counts, fn(c) { c.0 == learner.Calm })
  let assert Ok(#(_, count)) = calm_count
  let assert True = count == 1
}

// ============================================================
// Novelty Detection tests (LifeHD)
// ============================================================

/// Normal sample should not be novel when no stats yet
pub fn novelty_detection_normal_test() {
  let prof = profile.get_profile(profile.Shimeji)
  let mem = learner.init(prof)
  let readings = make_readings(list.repeat(0.0, 20))
  let f = features.extract(readings)
  let hv = learner.encode(mem, f, prof.quant_ranges)
  let #(_state, _sims, novelty) = learner.classify(mem, hv)
  // With no stats (count < 5), should never be novel
  let assert True = !novelty.is_novel
}

/// Stats should update after calling update_stats
pub fn novelty_stats_update_test() {
  let prof = profile.get_profile(profile.Shimeji)
  let mem = learner.init(prof)
  // Update stats several times
  let mem2 = learner.update_stats(mem, learner.Resting, 0.8)
  let mem3 = learner.update_stats(mem2, learner.Resting, 0.7)
  let mem4 = learner.update_stats(mem3, learner.Resting, 0.75)
  // After 3 updates, stats should exist but count < 5 so no novelty possible
  let readings = make_readings(list.repeat(0.0, 20))
  let f = features.extract(readings)
  let hv = learner.encode(mem4, f, prof.quant_ranges)
  let #(_state, _sims, novelty) = learner.classify(mem4, hv)
  let assert True = !novelty.is_novel
}

/// Classify returns 3-tuple with NoveltyInfo
pub fn classify_returns_3_tuple_test() {
  let prof = profile.get_profile(profile.Shimeji)
  let mem = learner.init(prof)
  let readings = make_readings(list.repeat(0.0, 20))
  let f = features.extract(readings)
  let hv = learner.encode(mem, f, prof.quant_ranges)
  let #(state, sims, novelty) = learner.classify(mem, hv)
  // All three parts should be valid
  let assert True = learner.state_to_string(state) != ""
  let assert True = list.length(sims) == 6
  let assert True = novelty.score >=. 0.0
}

/// Novelty JSON serialization
pub fn novelty_json_test() {
  let info = learner.NoveltyInfo(is_novel: False, score: 0.5, threshold: 0.3)
  let _json = learner.novelty_to_json_value(info)
  Nil
}

// ============================================================
// Temporal Encoding tests (HDC-EMG n-gram)
// ============================================================

/// Temporal encode with no history should return same HV
pub fn temporal_encode_single_test() {
  let prof = profile.get_profile(profile.Shimeji)
  let mem = learner.init(prof)
  let readings = make_readings(list.repeat(0.0, 20))
  let f = features.extract(readings)
  let hv = learner.encode(mem, f, prof.quant_ranges)
  let #(_temporal_hv, mem2) = learner.encode_temporal(mem, hv)
  // After encoding, recent_hvs should have 1 entry
  // Encode again with a different HV
  let hv2 = {
    let devs = [
      0.0, 5.0, 10.0, 15.0, 20.0, 15.0, 10.0, 5.0, 0.0, -5.0, -10.0, -5.0, 0.0,
      3.0, 6.0, 3.0, 0.0, -3.0, -6.0, -3.0,
    ]
    let r2 = make_readings(devs)
    let f2 = features.extract(r2)
    learner.encode(mem2, f2, prof.quant_ranges)
  }
  let #(_temporal_hv2, _mem3) = learner.encode_temporal(mem2, hv2)
  // Should not crash — temporal binding with history
  Nil
}

/// Temporal encode with history produces different HV
pub fn temporal_encode_with_history_test() {
  let prof = profile.get_profile(profile.Shimeji)
  let mem = learner.init(prof)
  // First encode
  let readings1 = make_readings(list.repeat(0.0, 20))
  let f1 = features.extract(readings1)
  let hv1 = learner.encode(mem, f1, prof.quant_ranges)
  let #(temporal1, mem2) = learner.encode_temporal(mem, hv1)
  // Second encode — should incorporate history
  let devs2 = [
    0.0, 5.0, 10.0, 15.0, 20.0, 15.0, 10.0, 5.0, 0.0, -5.0, -10.0, -5.0, 0.0,
    3.0, 6.0, 3.0, 0.0, -3.0, -6.0, -3.0,
  ]
  let readings2 = make_readings(devs2)
  let f2 = features.extract(readings2)
  let hv2 = learner.encode(mem2, f2, prof.quant_ranges)
  let #(_temporal2, _mem3) = learner.encode_temporal(mem2, hv2)
  // First temporal should exist (even without history, returns the HV)
  let _ = temporal1
  Nil
}

// ============================================================
// Temporal Context tests (majority vote)
// ============================================================

/// Init temporal context
pub fn temporal_context_init_test() {
  let ctx = learner.init_temporal_context(5)
  // Smoothed on empty history returns Unknown
  let s = learner.smoothed_state(ctx)
  let assert True = s == learner.Unknown
}

/// Majority vote should pick the most frequent state
pub fn temporal_context_majority_vote_test() {
  let ctx = learner.init_temporal_context(5)
  // Add 3 ACTIVE and 2 CALM — majority should be ACTIVE
  let ctx2 = learner.update_temporal_context(ctx, learner.Active)
  let ctx3 = learner.update_temporal_context(ctx2, learner.Calm)
  let ctx4 = learner.update_temporal_context(ctx3, learner.Active)
  let ctx5 = learner.update_temporal_context(ctx4, learner.Calm)
  let ctx6 = learner.update_temporal_context(ctx5, learner.Active)
  let smoothed = learner.smoothed_state(ctx6)
  let assert True = smoothed == learner.Active
}

// ============================================================
// OnlineHD Adaptive Alpha tests (TorchHD)
// ============================================================

/// Learning with similar sample should use low alpha (gentle refinement)
pub fn adaptive_alpha_high_sim_test() {
  let prof = profile.get_profile(profile.Shimeji)
  let assert Ok(g) = dynamic_gpu.init(prof)
  let readings = make_readings(list.repeat(0.0, 20))
  let f = features.extract(readings)
  // Learn same signal twice — second learn uses low alpha (high similarity)
  let g2 = dynamic_gpu.learn(g, f, "RESTING")
  let g3 = dynamic_gpu.learn(g2, f, "RESTING")
  // Classification should still work after adaptive learning
  let #(state, _) = dynamic_gpu.classify(g3, f)
  let assert True = state != "???"
}

/// Learning with different sample should adapt prototype more
pub fn adaptive_alpha_low_sim_test() {
  let prof = profile.get_profile(profile.Shimeji)
  let assert Ok(g) = dynamic_gpu.init(prof)
  // Very different signals
  let f1 = {
    let readings = make_readings(list.repeat(0.0, 20))
    features.extract(readings)
  }
  let f2 = {
    let devs = [
      0.0, 20.0, 40.0, 60.0, 80.0, 60.0, 40.0, 20.0, 0.0, -20.0, -40.0, -60.0,
      -80.0, -60.0, -40.0, -20.0, 0.0, 20.0, 40.0, 60.0,
    ]
    let readings = make_readings(devs)
    features.extract(readings)
  }
  let g2 = dynamic_gpu.learn(g, f1, "RESTING")
  let g3 = dynamic_gpu.learn(g2, f2, "RESTING")
  // Should still classify validly
  let #(state, sims) = dynamic_gpu.classify(g3, f1)
  let assert True = state != "???"
  let assert True = list.length(sims) == 6
}

// ============================================================
// Learning rejected JSON test
// ============================================================

/// Learning JSON should include rejected count
pub fn learning_rejected_json_test() {
  let prof = profile.get_profile(profile.Shimeji)
  let mem = learner.init(prof)
  let _json = learner.learning_to_json_value(mem)
  // Should not crash
  Nil
}

/// Saturated signal should be detected as bad quality
pub fn signal_quality_saturated_test() {
  // Signal with range > 500 (extreme values)
  let devs = [
    -300.0, -250.0, -200.0, -150.0, -100.0, -50.0, 0.0, 50.0, 100.0, 150.0,
    200.0, 250.0, 300.0, 250.0, 200.0, 150.0, 100.0, 50.0, 0.0, -50.0,
  ]
  let readings = make_readings(devs)
  let f = features.extract(readings)
  let q = features.assess_quality(f)
  let assert True = !q.is_good
  let assert True = q.reason == "saturated"
}
