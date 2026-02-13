//// Euclidean-Distance Classifier for fungal bioelectric signals
////
//// Pure Gleam CPU implementation — 19×6 = 114 multiply-adds is
//// faster on CPU than GPU upload/download overhead.
////
//// Architecture:
////   normalize(features) → negative Euclidean dist vs prototypes → softmax
////
//// Prototypes calibrated for Hypsizygus tessellatus (shimeji) mycelium.
//// Shimeji characteristics: σ~5mV at rest, spike trains 0.5-2Hz,
//// intracellular spikes 0.5-5mV (Olsson & Hansson 1995),
//// surface signals amplified by AD620 + 14-bit oversampling.

import gleam/float
import gleam/int
import gleam/json
import gleam/list
import gleam/string
import vivino/signal/features.{type SignalFeatures}

@external(erlang, "math", "exp")
fn math_exp(x: Float) -> Float

@external(erlang, "math", "sqrt")
fn math_sqrt(x: Float) -> Float

/// Classifier with precomputed L2-unit prototype vectors
pub type GpuClassifier {
  GpuClassifier(
    /// 6 L2-unit prototype vectors, each 19 elements
    /// Order: RESTING, CALM, ACTIVE, TRANSITION, STIMULUS, STRESS
    prototypes: List(List(Float)),
  )
}

const num_states = 6

/// Initialize classifier with calibrated prototypes
pub fn init() -> Result(GpuClassifier, String) {
  let protos = build_unit_prototypes()
  Ok(GpuClassifier(prototypes: protos))
}

/// Classify features via negative Euclidean distance
pub fn classify(
  gpu: GpuClassifier,
  f: SignalFeatures,
) -> #(String, List(#(String, Float))) {
  let raw = feature_list(f)
  let norm = normalize_features(raw)

  // Negative Euclidean distance as logit — closer = higher score
  let neg_dists =
    list.map(gpu.prototypes, fn(proto) {
      0.0 -. euclidean_distance(norm, proto)
    })

  make_result(softmax(neg_dists))
}

/// Euclidean distance between two vectors
fn euclidean_distance(a: List(Float), b: List(Float)) -> Float {
  let sum_sq =
    list.zip(a, b)
    |> list.fold(0.0, fn(acc, pair) {
      let d = pair.0 -. pair.1
      acc +. d *. d
    })
  math_sqrt(sum_sq)
}

/// Extract 19 time-domain features for classification (no MFCC)
pub fn feature_list(f: SignalFeatures) -> List(Float) {
  [
    f.mean, f.std, f.min_val, f.max_val, f.range, f.slope, f.energy, f.rms,
    f.dvdt_max, f.zcr, f.hjorth_mobility, f.hjorth_complexity, f.skewness,
    f.kurtosis, f.spectral_entropy, f.peak_count, f.autocorr_lag1, f.p25, f.p75,
  ]
}

// ============================================================
// Prototype construction
// ============================================================

/// Build L2-unit prototype vectors for each state
fn build_unit_prototypes() -> List(List(Float)) {
  // Raw prototypes per state — calibrated for shimeji mycelium
  // Shimeji resting: σ~5mV, range~23mV, dvdt~60mV/s (real data 2026-02-12)
  // Features: mean,std,min,max,range,slope,energy,rms,dvdt,zcr,hjM,hjC,skew,kurt,ent,peaks,acorr,p25,p75
  let raw_protos = [
    // RESTING: quiet mycelium, no stimulus — σ~5mV (REAL DATA)
    [
      2.0,
      5.0,
      -8.0,
      15.0,
      23.0,
      0.3,
      1500.0,
      5.5,
      60.0,
      0.1,
      0.35,
      2.2,
      1.0,
      2.0,
      0.7,
      4.0,
      0.91,
      -1.0,
      4.0,
    ],
    // CALM: subtle oscillation — σ~8mV, slow rhythmic changes
    [
      3.0,
      8.0,
      -15.0,
      25.0,
      40.0,
      2.0,
      4000.0,
      9.0,
      120.0,
      0.15,
      0.5,
      2.0,
      0.5,
      0.5,
      0.65,
      6.0,
      0.8,
      -4.0,
      8.0,
    ],
    // ACTIVE: spike trains — σ~15mV, rhythmic 0.5-2Hz (Adamatzky 2018)
    [
      5.0,
      15.0,
      -30.0,
      50.0,
      80.0,
      5.0,
      15_000.0,
      16.0,
      300.0,
      0.25,
      0.8,
      1.8,
      0.3,
      1.0,
      0.55,
      10.0,
      0.6,
      -10.0,
      15.0,
    ],
    // TRANSITION: propagating signal — directional slope, moderate std
    [
      8.0,
      10.0,
      -20.0,
      40.0,
      60.0,
      -12.0,
      6000.0,
      11.0,
      200.0,
      0.2,
      0.6,
      2.5,
      -0.5,
      1.5,
      0.6,
      7.0,
      0.7,
      -6.0,
      12.0,
    ],
    // STIMULUS: spike response — fast dV/dt, sharp peak (fungal AP-like)
    [
      15.0,
      25.0,
      -40.0,
      80.0,
      120.0,
      20.0,
      40_000.0,
      28.0,
      600.0,
      0.3,
      1.2,
      2.8,
      1.5,
      4.0,
      0.45,
      3.0,
      0.4,
      -20.0,
      35.0,
    ],
    // STRESS: sustained agitation — high σ, chaotic
    [
      20.0,
      40.0,
      -60.0,
      120.0,
      180.0,
      8.0,
      100_000.0,
      45.0,
      500.0,
      0.35,
      1.5,
      3.5,
      0.5,
      2.5,
      0.75,
      8.0,
      0.3,
      -30.0,
      50.0,
    ],
  ]

  // Normalize to [0,1] — Euclidean distance works directly
  list.map(raw_protos, fn(p) { normalize_features(p) })
}

// ============================================================
// Feature normalization (calibrated from real data)
// ============================================================

/// Normalize features to [0,1] using calibrated min/max bounds
/// Bounds calibrated for shimeji mycelium (much lower than tuber)
fn normalize_features(feats: List(Float)) -> List(Float) {
  let bounds = [
    #(-50.0, 50.0),
    // mean
    #(0.0, 50.0),
    // std
    #(-80.0, 100.0),
    // min_val
    #(-80.0, 150.0),
    // max_val
    #(0.0, 200.0),
    // range
    #(-30.0, 30.0),
    // slope
    #(0.0, 150_000.0),
    // energy
    #(0.0, 50.0),
    // rms
    #(0.0, 800.0),
    // dvdt_max
    #(0.0, 1.0),
    // zcr
    #(0.0, 3.0),
    // hjorth_mobility
    #(0.0, 6.0),
    // hjorth_complexity
    #(-3.0, 3.0),
    // skewness
    #(-2.0, 8.0),
    // kurtosis
    #(0.0, 1.0),
    // spectral_entropy
    #(0.0, 20.0),
    // peak_count
    #(-1.0, 1.0),
    // autocorr_lag1
    #(-50.0, 50.0),
    // p25
    #(-50.0, 50.0),
    // p75
  ]

  list.zip(feats, bounds)
  |> list.map(fn(pair) {
    let #(val, #(lo, hi)) = pair
    case hi -. lo >. 0.0 {
      True -> {
        let n = { val -. lo } /. { hi -. lo }
        float.clamp(n, 0.0, 1.0)
      }
      False -> 0.5
    }
  })
}

// ============================================================
// Softmax and result construction
// ============================================================

/// Numerically stable softmax with temperature
fn softmax(logits: List(Float)) -> List(Float) {
  // Cosine similarity of L2-unit vectors → range [-1, 1]
  // Lower temp = sharper discrimination between prototypes
  // Negative Euclidean distance: typical range [-2, 0]
  // Lower temp → sharper discrimination
  let temp = 0.08
  let scaled = list.map(logits, fn(x) { x /. temp })

  let max_val =
    list.fold(scaled, -1000.0, fn(acc, x) {
      case x >. acc {
        True -> x
        False -> acc
      }
    })

  let exps = list.map(scaled, fn(x) { math_exp(x -. max_val) })
  let sum = list.fold(exps, 0.0, fn(acc, x) { acc +. x })

  case sum >. 0.0 {
    True -> list.map(exps, fn(x) { x /. sum })
    False -> list.repeat(1.0 /. int.to_float(num_states), num_states)
  }
}

fn make_result(probs: List(Float)) -> #(String, List(#(String, Float))) {
  let states = state_names()
  let pairs = list.zip(states, probs)

  let best =
    list.fold(pairs, #("???", 0.0), fn(acc, pair) {
      case pair.1 >. acc.1 {
        True -> pair
        False -> acc
      }
    })

  #(best.0, pairs)
}

fn state_names() -> List(String) {
  ["RESTING", "CALM", "ACTIVE", "TRANSITION", "STIMULUS", "STRESS"]
}

// ============================================================
// Display and JSON
// ============================================================

/// Format results for terminal display
pub fn format_results(results: List(#(String, Float))) -> String {
  results
  |> list.map(fn(r) {
    r.0 <> ":" <> float.to_string(float.multiply(r.1, 100.0)) <> "%"
  })
  |> string.join(" | ")
}

/// Results as JSON value
pub fn results_to_json_value(results: List(#(String, Float))) -> json.Json {
  results
  |> list.map(fn(r) { #(r.0, json.float(r.1)) })
  |> json.object
}
