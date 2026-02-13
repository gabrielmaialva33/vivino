//// Signal feature extraction using viva_tensor.
////
//// Transforms raw readings into feature vectors for classification.
//// Calibrated for Hypsizygus tessellatus (shimeji) mycelium.
////
//// Shimeji calibration (50-sample window @ 20Hz = 2.5s):
////   Resting: std <3,    range <15,   energy <500
////   Calm:    std 3-8,   range 15-40,  energy 500-3k
////   Active:  std 8-20,  range 40-100, energy 3k-20k
////   Strong:  std >25,   range >120,  energy >20k
////   dV/dt calm: ~60 mV/s, >500 = spike-like (fungal threshold)
////
//// Refs: Adamatzky 2018 (spike trains 0.5-2Hz),
////       Olsson & Hansson 1995 (intracellular 0.5-5mV),
////       Slayman 1976 (Neurospora action potentials)

import gleam/float
import gleam/int
import gleam/json
import gleam/list
import gleam/result
import viva_tensor as t
import vivino/serial/parser.{type Reading}

// Erlang math FFI for MFCC spectral analysis
@external(erlang, "math", "cos")
fn math_cos(x: Float) -> Float

@external(erlang, "math", "log")
fn math_ln(x: Float) -> Float

@external(erlang, "math", "log10")
fn math_log10(x: Float) -> Float

@external(erlang, "math", "pi")
fn math_pi() -> Float

/// Extracted signal features from a window of readings
/// 19 time-domain + 8 MFCC = 27 total features
pub type SignalFeatures {
  SignalFeatures(
    mean: Float,
    std: Float,
    min_val: Float,
    max_val: Float,
    range: Float,
    slope: Float,
    energy: Float,
    rms: Float,
    dvdt_max: Float,
    zcr: Float,
    hjorth_mobility: Float,
    hjorth_complexity: Float,
    // New features (Vivent-inspired)
    skewness: Float,
    kurtosis: Float,
    spectral_entropy: Float,
    peak_count: Float,
    autocorr_lag1: Float,
    p25: Float,
    p75: Float,
    mfcc: List(Float),
  )
}

/// Extract features from a list of readings using tensor operations
pub fn extract(readings: List(Reading)) -> SignalFeatures {
  let deviations = list.map(readings, fn(r) { r.deviation })
  let tensor = t.from_list(deviations)

  let mean = t.mean(tensor)
  let std = t.std(tensor)
  let min_val = t.min(tensor)
  let max_val = t.max(tensor)
  let range = max_val -. min_val

  let n = list.length(deviations)
  let third = n / 3
  let slope = case third > 0 {
    True -> {
      let first_third = deviations |> list.take(third) |> t.from_list |> t.mean
      let last_third =
        deviations |> list.drop(n - third) |> t.from_list |> t.mean
      last_third -. first_third
    }
    False -> 0.0
  }

  let norm = t.norm(tensor)
  let energy = norm *. norm

  let rms = case n > 0 {
    True -> float.square_root(energy /. int.to_float(n)) |> result.unwrap(0.0)
    False -> 0.0
  }

  let dvdt_max = compute_dvdt_max(deviations)
  let zcr = compute_zcr(deviations, mean)
  let #(hjorth_mob, hjorth_cmp) = compute_hjorth(deviations)
  let mfcc = compute_mfcc(deviations)

  // New features
  let skewness = compute_skewness(deviations, mean, std)
  let kurtosis = compute_kurtosis(deviations, mean, std)
  let spectral_entropy = compute_spectral_entropy(deviations)
  let peak_count = compute_peak_count(deviations)
  let autocorr_lag1 = compute_autocorr(deviations, mean)
  let #(p25, p75) = compute_percentiles(deviations)

  SignalFeatures(
    mean:,
    std:,
    min_val:,
    max_val:,
    range:,
    slope:,
    energy:,
    rms:,
    dvdt_max:,
    zcr:,
    hjorth_mobility: hjorth_mob,
    hjorth_complexity: hjorth_cmp,
    skewness:,
    kurtosis:,
    spectral_entropy:,
    peak_count:,
    autocorr_lag1:,
    p25:,
    p75:,
    mfcc:,
  )
}

/// Max absolute dV/dt in the window (mV/s, at 20Hz sampling)
fn compute_dvdt_max(values: List(Float)) -> Float {
  case values {
    [] | [_] -> 0.0
    [first, ..rest] -> dvdt_loop(rest, first, 0.0) *. 20.0
  }
}

fn dvdt_loop(values: List(Float), prev: Float, best: Float) -> Float {
  case values {
    [] -> best
    [v, ..rest] -> {
      let delta = float.absolute_value(v -. prev)
      dvdt_loop(rest, v, case delta >. best {
        True -> delta
        False -> best
      })
    }
  }
}

/// Zero-crossing rate around the mean
fn compute_zcr(values: List(Float), mean: Float) -> Float {
  case values {
    [] | [_] -> 0.0
    [first, ..rest] -> {
      let #(crossings, count) = zcr_loop(rest, first -. mean, 0, 0, mean)
      case count > 0 {
        True -> int.to_float(crossings) /. int.to_float(count)
        False -> 0.0
      }
    }
  }
}

fn zcr_loop(
  values: List(Float),
  prev_c: Float,
  crossings: Int,
  count: Int,
  mean: Float,
) -> #(Int, Int) {
  case values {
    [] -> #(crossings, count)
    [v, ..rest] -> {
      let curr_c = v -. mean
      let cross = case prev_c *. curr_c <. 0.0 {
        True -> 1
        False -> 0
      }
      zcr_loop(rest, curr_c, crossings + cross, count + 1, mean)
    }
  }
}

/// Hjorth Mobility and Complexity
fn compute_hjorth(values: List(Float)) -> #(Float, Float) {
  case list.length(values) < 4 {
    True -> #(0.0, 0.0)
    False -> {
      let d1 = differences(values)
      let d2 = differences(d1)
      let var0 = variance(values)
      let var1 = variance(d1)
      let var2 = variance(d2)

      let mobility = case var0 >. 0.0 {
        True -> float.square_root(var1 /. var0) |> result.unwrap(0.0)
        False -> 0.0
      }
      let complexity = case var1 >. 0.0 && mobility >. 0.0 {
        True -> {
          let mob_d1 = float.square_root(var2 /. var1) |> result.unwrap(0.0)
          mob_d1 /. mobility
        }
        False -> 0.0
      }
      #(mobility, complexity)
    }
  }
}

fn differences(values: List(Float)) -> List(Float) {
  case values {
    [] | [_] -> []
    [a, b, ..rest] -> [b -. a, ..differences([b, ..rest])]
  }
}

fn variance(values: List(Float)) -> Float {
  let n = list.length(values)
  case n {
    0 -> 0.0
    _ -> {
      let nf = int.to_float(n)
      let mean = list.fold(values, 0.0, fn(acc, v) { acc +. v }) /. nf
      list.fold(values, 0.0, fn(acc, v) {
        let d = v -. mean
        acc +. { d *. d }
      })
      /. nf
    }
  }
}

// ============================================
// MFCC: Goertzel + Mel Filterbank + DCT-II
// Plant signals 0.5-25Hz @ 50Hz effective rate
// Goertzel is O(N) per freq — optimal for sparse spectrum
// ============================================

const mfcc_num_filters = 12

const mfcc_num_coeffs = 8

const mfcc_sample_rate = 20.0

fn hz_to_mel(f: Float) -> Float {
  2595.0 *. math_log10(1.0 +. f /. 700.0)
}

fn mel_to_hz(m: Float) -> Float {
  700.0 *. { result.unwrap(float.power(10.0, m /. 2595.0), 1.0) -. 1.0 }
}

/// Mel filterbank edge frequencies (num_filters + 2 points)
fn mel_edges() -> List(Float) {
  let mel_min = hz_to_mel(0.5)
  let mel_max = hz_to_mel(25.0)
  let num_points = mfcc_num_filters + 2
  let step = { mel_max -. mel_min } /. int.to_float(num_points - 1)
  int.range(from: 0, to: num_points - 1, with: [], run: fn(acc, i) {
    [mel_to_hz(mel_min +. int.to_float(i) *. step), ..acc]
  })
  |> list.reverse
}

/// Goertzel: DFT power at one frequency, O(N)
fn goertzel_power(samples: List(Float), target_freq: Float) -> Float {
  let n = list.length(samples)
  let nf = int.to_float(n)
  let k = float.round(nf *. target_freq /. mfcc_sample_rate)
  let omega = 2.0 *. math_pi() *. int.to_float(k) /. nf
  let coeff = 2.0 *. math_cos(omega)

  let #(s1, s2) =
    list.fold(samples, #(0.0, 0.0), fn(acc, sample) {
      let #(sp1, sp2) = acc
      let s = sample +. coeff *. sp1 -. sp2
      #(s, sp1)
    })

  float.absolute_value(s2 *. s2 +. s1 *. s1 -. coeff *. s1 *. s2)
}

/// Hamming window
fn hamming_window(samples: List(Float)) -> List(Float) {
  let nm1 = int.to_float(list.length(samples) - 1)
  let pi2 = 2.0 *. math_pi()
  hamming_loop(samples, 0, nm1, pi2)
}

fn hamming_loop(
  samples: List(Float),
  i: Int,
  nm1: Float,
  pi2: Float,
) -> List(Float) {
  case samples {
    [] -> []
    [x, ..rest] -> {
      let w = case nm1 >. 0.0 {
        True -> 0.54 -. 0.46 *. math_cos(pi2 *. int.to_float(i) /. nm1)
        False -> 1.0
      }
      [x *. w, ..hamming_loop(rest, i + 1, nm1, pi2)]
    }
  }
}

/// Mel spectrum via triangular filterbank + Goertzel
fn compute_mel_spectrum(windowed: List(Float)) -> List(Float) {
  let edges = mel_edges()
  mel_filter_loop(edges, windowed, [])
}

fn mel_filter_loop(
  edges: List(Float),
  samples: List(Float),
  acc: List(Float),
) -> List(Float) {
  case edges {
    [lo, mid, hi, ..rest] -> {
      let p_lo = goertzel_power(samples, lo)
      let p_mid = goertzel_power(samples, mid)
      let p_hi = goertzel_power(samples, hi)
      let energy = 0.25 *. p_lo +. 0.5 *. p_mid +. 0.25 *. p_hi
      mel_filter_loop([mid, hi, ..rest], samples, [energy, ..acc])
    }
    _ -> list.reverse(acc)
  }
}

/// DCT Type-II (skip C0 energy, take C1..C_num_coeffs)
fn dct_ii(log_spectrum: List(Float)) -> List(Float) {
  let m = int.to_float(list.length(log_spectrum))
  let pi = math_pi()
  int.range(from: 1, to: mfcc_num_coeffs, with: [], run: fn(acc, n) {
    [dct_sum(log_spectrum, 0, int.to_float(n), m, pi), ..acc]
  })
  |> list.reverse
}

fn dct_sum(
  values: List(Float),
  idx: Int,
  n: Float,
  m: Float,
  pi: Float,
) -> Float {
  case values {
    [] -> 0.0
    [v, ..rest] ->
      v
      *. math_cos(pi *. n *. { int.to_float(idx) +. 0.5 } /. m)
      +. dct_sum(rest, idx + 1, n, m, pi)
  }
}

/// Full MFCC pipeline: Hamming → Goertzel mel spectrum → log → DCT
fn compute_mfcc(deviations: List(Float)) -> List(Float) {
  case list.length(deviations) < 8 {
    True -> list.repeat(0.0, mfcc_num_coeffs)
    False -> {
      let windowed = hamming_window(deviations)
      let mel_spec = compute_mel_spectrum(windowed)
      let log_spec =
        list.map(mel_spec, fn(x) {
          case x >. 1.0e-10 {
            True -> math_ln(x)
            False -> math_ln(1.0e-10)
          }
        })
      dct_ii(log_spec)
    }
  }
}

// ============================================
// New features: skewness, kurtosis, spectral entropy,
// peak count, autocorrelation, percentiles
// Inspired by Vivent SA (2025) potato sprouting paper
// ============================================

/// Skewness (3rd standardized moment) — asymmetry indicator
fn compute_skewness(values: List(Float), mean: Float, std: Float) -> Float {
  case std >. 0.001 {
    True -> {
      let n = int.to_float(list.length(values))
      let sum3 =
        list.fold(values, 0.0, fn(acc, v) {
          let d = v -. mean
          acc +. d *. d *. d
        })
      sum3 /. { n *. std *. std *. std }
    }
    False -> 0.0
  }
}

/// Kurtosis (4th standardized moment) — tail heaviness
fn compute_kurtosis(values: List(Float), mean: Float, std: Float) -> Float {
  case std >. 0.001 {
    True -> {
      let n = int.to_float(list.length(values))
      let var = std *. std
      let sum4 =
        list.fold(values, 0.0, fn(acc, v) {
          let d = v -. mean
          acc +. d *. d *. d *. d
        })
      { sum4 /. { n *. var *. var } } -. 3.0
    }
    False -> 0.0
  }
}

/// Spectral entropy from mel spectrum — signal complexity measure
fn compute_spectral_entropy(values: List(Float)) -> Float {
  case list.length(values) < 8 {
    True -> 0.0
    False -> {
      let windowed = hamming_window(values)
      let mel_spec = compute_mel_spectrum(windowed)
      let total =
        list.fold(mel_spec, 0.0, fn(acc, x) { acc +. float.absolute_value(x) })
      case total >. 1.0e-10 {
        True -> {
          let probs =
            list.map(mel_spec, fn(x) { float.absolute_value(x) /. total })
          let entropy =
            list.fold(probs, 0.0, fn(acc, p) {
              case p >. 1.0e-10 {
                True -> acc -. p *. math_ln(p)
                False -> acc
              }
            })
          // Normalize by log(num_filters)
          entropy /. math_ln(12.0)
        }
        False -> 0.0
      }
    }
  }
}

/// Peak count — number of local maxima in window
fn compute_peak_count(values: List(Float)) -> Float {
  int.to_float(peak_loop(values, 0))
}

fn peak_loop(values: List(Float), count: Int) -> Int {
  case values {
    [a, b, c, ..rest] ->
      case b >. a && b >. c {
        True -> peak_loop([b, c, ..rest], count + 1)
        False -> peak_loop([b, c, ..rest], count)
      }
    _ -> count
  }
}

/// Autocorrelation at lag 1 — temporal self-similarity
fn compute_autocorr(values: List(Float), mean: Float) -> Float {
  let centered = list.map(values, fn(v) { v -. mean })
  let var = list.fold(centered, 0.0, fn(acc, v) { acc +. v *. v })
  case var >. 0.001 {
    True -> {
      let cov = autocorr_sum(centered, 0.0)
      cov /. var
    }
    False -> 0.0
  }
}

fn autocorr_sum(values: List(Float), acc: Float) -> Float {
  case values {
    [a, b, ..rest] -> autocorr_sum([b, ..rest], acc +. a *. b)
    _ -> acc
  }
}

/// Percentiles (25th, 75th) via sorted list
fn compute_percentiles(values: List(Float)) -> #(Float, Float) {
  let sorted = list.sort(values, float.compare)
  let n = list.length(sorted)
  case n > 0 {
    True -> {
      let i25 = { n * 25 } / 100
      let i75 = { n * 75 } / 100
      let p25 = list_at_float(sorted, i25)
      let p75 = list_at_float(sorted, i75)
      #(p25, p75)
    }
    False -> #(0.0, 0.0)
  }
}

fn list_at_float(lst: List(Float), idx: Int) -> Float {
  case list.drop(lst, idx) {
    [val, ..] -> val
    [] -> 0.0
  }
}

/// Normalize readings using z-score
pub fn normalize(readings: List(Reading)) -> t.Tensor {
  let values = list.map(readings, fn(r) { r.deviation })
  let tensor = t.from_list(values)
  let mean = t.mean(tensor)
  let std = t.std(tensor)

  case std >. 0.0 {
    True -> t.map(tensor, fn(x) { { x -. mean } /. std })
    False -> t.zeros([list.length(values)])
  }
}

/// Convert features to tensor vector (19 time-domain + 8 MFCC = 27)
pub fn to_tensor(f: SignalFeatures) -> t.Tensor {
  t.from_list(list.append(
    [
      f.mean, f.std, f.min_val, f.max_val, f.range, f.slope, f.energy, f.rms,
      f.dvdt_max, f.zcr, f.hjorth_mobility, f.hjorth_complexity, f.skewness,
      f.kurtosis, f.spectral_entropy, f.peak_count, f.autocorr_lag1, f.p25,
      f.p75,
    ],
    f.mfcc,
  ))
}

/// Classify state based on calibrated thresholds (shimeji mycelium)
/// Shimeji signals are ~10-15x weaker than sweet potato tuber
pub fn classify_state(f: SignalFeatures) -> String {
  let abs_slope = float.absolute_value(f.slope)

  // Spike-like: fast transient + high range (fungal threshold)
  case f.dvdt_max >. 500.0 && f.range >. 60.0 {
    True -> "STRONG_STIMULUS"
    False ->
      case True {
        _ if f.std <. 3.0 && f.range <. 15.0 -> "RESTING"
        _ if f.std >. 25.0 -> "AGITATED"
        _ if f.range >. 120.0 -> "STRONG_STIMULUS"
        _ if abs_slope >. 8.0 && f.std >. 6.0 -> "TRANSITION"
        _ if f.std >. 8.0 -> "ACTIVE"
        _ if f.std >. 3.0 -> "CALM"
        _ -> "RESTING"
      }
  }
}

/// Convert features to JSON
pub fn to_json(f: SignalFeatures) -> String {
  to_json_value(f) |> json.to_string
}

/// Features as json.Json value
pub fn to_json_value(f: SignalFeatures) -> json.Json {
  json.object([
    #("mean", json.float(f.mean)),
    #("std", json.float(f.std)),
    #("range", json.float(f.range)),
    #("slope", json.float(f.slope)),
    #("energy", json.float(f.energy)),
    #("rms", json.float(f.rms)),
    #("dvdt_max", json.float(f.dvdt_max)),
    #("zcr", json.float(f.zcr)),
    #("hjorth_mob", json.float(f.hjorth_mobility)),
    #("hjorth_cmp", json.float(f.hjorth_complexity)),
    #("skewness", json.float(f.skewness)),
    #("kurtosis", json.float(f.kurtosis)),
    #("spec_entropy", json.float(f.spectral_entropy)),
    #("peak_count", json.float(f.peak_count)),
    #("autocorr", json.float(f.autocorr_lag1)),
    #("p25", json.float(f.p25)),
    #("p75", json.float(f.p75)),
    #("state", json.string(classify_state(f))),
    #("mfcc", json.array(f.mfcc, json.float)),
  ])
}
