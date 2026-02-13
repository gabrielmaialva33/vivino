//// Profile-parameterized GPU classifier with OnlineHD adaptive learning.
////
//// Same euclidean distance + softmax architecture as gpu.gleam,
//// but prototypes, bounds, and temperature come from OrganismProfile.
//// Online learning via similarity-weighted EMA (OnlineHD/TorchHD approach):
//// alpha = base_lr * (1 - similarity) — learns more from novel samples.

import gleam/float
import gleam/int
import gleam/json
import gleam/list
import gleam/string
import vivino/signal/features.{type SignalFeatures}
import vivino/signal/profile.{type OrganismProfile}

@external(erlang, "math", "exp")
fn math_exp(x: Float) -> Float

@external(erlang, "math", "sqrt")
fn math_sqrt(x: Float) -> Float

/// Dynamic GPU classifier
pub type DynamicGpuClassifier {
  DynamicGpuClassifier(
    /// 6 L2-unit prototype vectors, each 19 elements
    prototypes: List(List(Float)),
    /// 19 normalization bounds
    bounds: List(#(Float, Float)),
    /// Softmax temperature
    temp: Float,
  )
}

const num_states = 6

/// OnlineHD base learning rate (TorchHD-inspired)
const base_lr = 0.2

/// Initialize from organism profile
pub fn init(profile: OrganismProfile) -> Result(DynamicGpuClassifier, String) {
  let protos =
    list.map(profile.gpu_prototypes, fn(p) {
      normalize_features(p, profile.gpu_bounds)
    })
  Ok(DynamicGpuClassifier(
    prototypes: protos,
    bounds: profile.gpu_bounds,
    temp: profile.softmax_temp,
  ))
}

/// Classify features via negative Euclidean distance
pub fn classify(
  gpu: DynamicGpuClassifier,
  f: SignalFeatures,
) -> #(String, List(#(String, Float))) {
  let raw = feature_list(f)
  let norm = normalize_features(raw, gpu.bounds)

  let neg_dists =
    list.map(gpu.prototypes, fn(proto) {
      0.0 -. euclidean_distance(norm, proto)
    })

  make_result(softmax(neg_dists, gpu.temp))
}

/// Learn from a labeled sample via OnlineHD similarity-weighted EMA
///
/// Alpha = base_lr * (1 - cosine_similarity) — novel samples get larger
/// updates, familiar samples get gentle refinement. TorchHD-inspired.
pub fn learn(
  gpu: DynamicGpuClassifier,
  f: SignalFeatures,
  state_name: String,
) -> DynamicGpuClassifier {
  let raw = feature_list(f)
  let norm = normalize_features(raw, gpu.bounds)

  let names = state_names()
  let state_idx = find_index(names, state_name, 0)

  case state_idx >= 0 && state_idx < num_states {
    True -> {
      let new_protos =
        list.index_map(gpu.prototypes, fn(proto, i) {
          case i == state_idx {
            True -> {
              // OnlineHD: alpha = base_lr * (1 - similarity)
              let sim = cosine_similarity(norm, proto)
              let alpha = float.clamp(base_lr *. { 1.0 -. sim }, 0.01, 0.3)
              let updated =
                list.zip(norm, proto)
                |> list.map(fn(pair) {
                  alpha *. pair.0 +. { 1.0 -. alpha } *. pair.1
                })
              l2_normalize(updated)
            }
            False -> proto
          }
        })
      DynamicGpuClassifier(..gpu, prototypes: new_protos)
    }
    False -> gpu
  }
}

fn find_index(items: List(String), target: String, idx: Int) -> Int {
  case items {
    [] -> -1
    [first, ..rest] ->
      case first == target {
        True -> idx
        False -> find_index(rest, target, idx + 1)
      }
  }
}

/// Extract 19 time-domain features
pub fn feature_list(f: SignalFeatures) -> List(Float) {
  [
    f.mean, f.std, f.min_val, f.max_val, f.range, f.slope, f.energy, f.rms,
    f.dvdt_max, f.zcr, f.hjorth_mobility, f.hjorth_complexity, f.skewness,
    f.kurtosis, f.spectral_entropy, f.peak_count, f.autocorr_lag1, f.p25, f.p75,
  ]
}

/// Normalize features to [0,1] using bounds
fn normalize_features(
  feats: List(Float),
  bounds: List(#(Float, Float)),
) -> List(Float) {
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

/// Cosine similarity between two vectors (for OnlineHD alpha)
fn cosine_similarity(a: List(Float), b: List(Float)) -> Float {
  let #(dot, norm_a, norm_b) =
    list.zip(a, b)
    |> list.fold(#(0.0, 0.0, 0.0), fn(acc, pair) {
      let #(d, na, nb) = acc
      #(d +. pair.0 *. pair.1, na +. pair.0 *. pair.0, nb +. pair.1 *. pair.1)
    })
  let denom = math_sqrt(norm_a) *. math_sqrt(norm_b)
  case denom >. 0.0 {
    True -> float.clamp(dot /. denom, -1.0, 1.0)
    False -> 0.0
  }
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

/// L2 normalize a vector to unit length
fn l2_normalize(vec: List(Float)) -> List(Float) {
  let sum_sq = list.fold(vec, 0.0, fn(acc, x) { acc +. x *. x })
  let norm = math_sqrt(sum_sq)
  case norm >. 0.0 {
    True -> list.map(vec, fn(x) { x /. norm })
    False -> vec
  }
}

/// Numerically stable softmax with temperature
fn softmax(logits: List(Float), temp: Float) -> List(Float) {
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

/// Format results for display
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
