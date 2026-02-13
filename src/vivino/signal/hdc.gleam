//// Hyperdimensional Computing classifier for plant states.
////
//// Uses binary hypervectors (10,048 dims) to encode and classify
//// bioelectric signal patterns. One-shot learning capable.

import gleam/float
import gleam/int
import gleam/json
import gleam/list
import gleam/string
import gleam/yielder
import viva_tensor/hdc.{type HyperVector}
import vivino/signal/features.{type SignalFeatures}

/// Possible plant states
pub type PlantState {
  Resting
  Calm
  Active
  Stimulus
  Stress
  Unknown
}

/// HDC associative memory
pub type HdcMemory {
  HdcMemory(
    // State prototypes
    resting: HyperVector,
    calm: HyperVector,
    active: HyperVector,
    stimulus: HyperVector,
    stress: HyperVector,
    // Role vectors for features
    role_mean: HyperVector,
    role_std: HyperVector,
    role_range: HyperVector,
    role_slope: HyperVector,
    role_energy: HyperVector,
    // Level vectors (quantization)
    levels: List(HyperVector),
  )
}

/// Hypervector dimensionality
const dim = 10_048

/// Number of quantization levels
const num_levels = 16

/// Initialize HDC memory with prototypes and role vectors
pub fn init() -> HdcMemory {
  // State prototypes (fixed seeds for reproducibility)
  let resting = hdc.random(dim, 1)
  let calm = hdc.random(dim, 2)
  let active = hdc.random(dim, 3)
  let stimulus = hdc.random(dim, 4)
  let stress = hdc.random(dim, 5)

  // Role vectors (one per feature)
  let role_mean = hdc.random(dim, 100)
  let role_std = hdc.random(dim, 101)
  let role_range = hdc.random(dim, 102)
  let role_slope = hdc.random(dim, 103)
  let role_energy = hdc.random(dim, 104)

  // Level vectors (16 quantization levels)
  let levels =
    yielder.range(from: 0, to: num_levels - 1)
    |> yielder.to_list
    |> list.map(fn(i) { hdc.random(dim, 200 + i) })

  HdcMemory(
    resting:,
    calm:,
    active:,
    stimulus:,
    stress:,
    role_mean:,
    role_std:,
    role_range:,
    role_slope:,
    role_energy:,
    levels:,
  )
}

/// Quantize a float value to a level index [0, num_levels-1]
fn quantize(value: Float, min_val: Float, max_val: Float) -> Int {
  case max_val -. min_val >. 0.0 {
    True -> {
      let normalized = { value -. min_val } /. { max_val -. min_val }
      let level = float.round(normalized *. int.to_float(num_levels - 1))
      int.clamp(level, 0, num_levels - 1)
    }
    False -> num_levels / 2
  }
}

/// Get level vector by index
fn get_level(memory: HdcMemory, idx: Int) -> HyperVector {
  case list.drop(memory.levels, idx) {
    [level, ..] -> level
    [] -> {
      let assert [last, ..] = list.reverse(memory.levels)
      last
    }
  }
}

/// Encode signal features as a hypervector via role-binding
/// Ranges calibrated for sweet potato tuber tissue:
///   mean:   [-500, 500] mV (deviation, tuber tighter range)
///   std:    [0, 300] mV (50-sample window)
///   range:  [0, 1600] mV
///   slope:  [-400, 400] mV (wound recovery slopes)
///   energy: [0, 2_500_000] (L2² of 50 deviation samples)
pub fn encode(memory: HdcMemory, f: SignalFeatures) -> HyperVector {
  let mean_lv = get_level(memory, quantize(f.mean, -500.0, 500.0))
  let std_lv = get_level(memory, quantize(f.std, 0.0, 300.0))
  let range_lv = get_level(memory, quantize(f.range, 0.0, 1600.0))
  let slope_lv = get_level(memory, quantize(f.slope, -400.0, 400.0))
  let energy_lv = get_level(memory, quantize(f.energy, 0.0, 2_500_000.0))

  // Bind role with level: role XOR level_vector
  hdc.bind(memory.role_mean, mean_lv)
  |> hdc.bind(hdc.bind(memory.role_std, std_lv))
  |> hdc.bind(hdc.bind(memory.role_range, range_lv))
  |> hdc.bind(hdc.bind(memory.role_slope, slope_lv))
  |> hdc.bind(hdc.bind(memory.role_energy, energy_lv))
}

/// Classify a signal by comparing with prototypes
pub fn classify(memory: HdcMemory, signal_hv: HyperVector) -> PlantState {
  let sims = similarities(memory, signal_hv)
  let best =
    list.fold(sims, #(Unknown, 0.0), fn(acc, item) {
      case item.1 >. acc.1 {
        True -> #(item.0, item.1)
        False -> acc
      }
    })
  best.0
}

/// Get similarities with all state prototypes
pub fn similarities(
  memory: HdcMemory,
  signal_hv: HyperVector,
) -> List(#(PlantState, Float)) {
  [
    #(Resting, hdc.similarity(signal_hv, memory.resting)),
    #(Calm, hdc.similarity(signal_hv, memory.calm)),
    #(Active, hdc.similarity(signal_hv, memory.active)),
    #(Stimulus, hdc.similarity(signal_hv, memory.stimulus)),
    #(Stress, hdc.similarity(signal_hv, memory.stress)),
  ]
}

/// Convert plant state to string
pub fn state_to_string(state: PlantState) -> String {
  case state {
    Resting -> "RESTING"
    Calm -> "CALM"
    Active -> "ACTIVE"
    Stimulus -> "STIMULUS"
    Stress -> "STRESS"
    Unknown -> "???"
  }
}

/// Format similarities for display
pub fn format_similarities(sims: List(#(PlantState, Float))) -> String {
  sims
  |> list.map(fn(s) {
    state_to_string(s.0)
    <> ":"
    <> float.to_string(float.multiply(s.1, 100.0))
    <> "%"
  })
  |> string.join(" | ")
}

/// Similarities to JSON string (legacy)
pub fn similarities_to_json(sims: List(#(PlantState, Float))) -> String {
  similarities_to_json_value(sims) |> json.to_string
}

/// Similarities as json.Json value (for composing with gleam_json)
pub fn similarities_to_json_value(sims: List(#(PlantState, Float))) -> json.Json {
  sims
  |> list.map(fn(s) { #(state_to_string(s.0), json.float(s.1)) })
  |> json.object
}
