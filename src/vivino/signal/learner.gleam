//// Dynamic HDC classifier with online learning.
////
//// Uses k-NN in hyperdimensional space: classifies by comparing
//// against stored exemplars + initial prototypes.
//// No bundle operation needed — works with similarity only.

import gleam/float
import gleam/int
import gleam/json
import gleam/list
import gleam/string
import gleam/yielder
import viva_tensor/hdc.{type HyperVector}
import vivino/signal/features.{type SignalFeatures}
import vivino/signal/profile.{type OrganismProfile, type QuantRanges}

/// Unified plant state (6 + Unknown)
pub type PlantState {
  Resting
  Calm
  Active
  Transition
  Stimulus
  Stress
  Unknown
}

/// A labeled exemplar in HD space
pub type Exemplar {
  Exemplar(hv: HyperVector, state: PlantState, timestamp: Float)
}

/// Dynamic HDC memory with online learning
pub type DynamicHdcMemory {
  DynamicHdcMemory(
    // Role vectors for feature binding
    role_mean: HyperVector,
    role_std: HyperVector,
    role_range: HyperVector,
    role_slope: HyperVector,
    role_energy: HyperVector,
    // Quantization level vectors
    levels: List(HyperVector),
    // Initial prototypes from profile
    initial_prototypes: List(#(PlantState, HyperVector)),
    // Learned exemplars (k-NN buffer)
    exemplars: List(Exemplar),
    // Max exemplars per state
    max_per_state: Int,
    // Calibration tracking
    sample_count: Int,
    calibration_complete: Bool,
  )
}

/// Hypervector dimensionality
const dim = 10_048

/// Number of quantization levels
const num_levels = 16

/// Samples for auto-calibration (3s @ 20Hz)
const calibration_samples = 60

/// Max exemplars per state in ring buffer
const default_max_per_state = 5

/// Initialize dynamic HDC memory from an organism profile
pub fn init(_profile: OrganismProfile) -> DynamicHdcMemory {
  // Role vectors (deterministic seeds)
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

  // Initial prototypes (random seeds, same across profiles)
  let initial_prototypes = [
    #(Resting, hdc.random(dim, 1)),
    #(Calm, hdc.random(dim, 2)),
    #(Active, hdc.random(dim, 3)),
    #(Transition, hdc.random(dim, 6)),
    #(Stimulus, hdc.random(dim, 4)),
    #(Stress, hdc.random(dim, 5)),
  ]

  DynamicHdcMemory(
    role_mean:,
    role_std:,
    role_range:,
    role_slope:,
    role_energy:,
    levels:,
    initial_prototypes:,
    exemplars: [],
    max_per_state: default_max_per_state,
    sample_count: 0,
    calibration_complete: False,
  )
}

/// Quantize a float to level index [0, num_levels-1]
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
fn get_level(memory: DynamicHdcMemory, idx: Int) -> HyperVector {
  case list.drop(memory.levels, idx) {
    [level, ..] -> level
    [] -> {
      let assert [last, ..] = list.reverse(memory.levels)
      last
    }
  }
}

/// Encode signal features into a hypervector using profile-specific ranges
pub fn encode(
  memory: DynamicHdcMemory,
  f: SignalFeatures,
  ranges: QuantRanges,
) -> HyperVector {
  let mean_lv =
    get_level(memory, quantize(f.mean, ranges.mean_min, ranges.mean_max))
  let std_lv =
    get_level(memory, quantize(f.std, ranges.std_min, ranges.std_max))
  let range_lv =
    get_level(memory, quantize(f.range, ranges.range_min, ranges.range_max))
  let slope_lv =
    get_level(memory, quantize(f.slope, ranges.slope_min, ranges.slope_max))
  let energy_lv =
    get_level(memory, quantize(f.energy, ranges.energy_min, ranges.energy_max))

  // Bind role ⊕ level for each feature, then chain
  hdc.bind(memory.role_mean, mean_lv)
  |> hdc.bind(hdc.bind(memory.role_std, std_lv))
  |> hdc.bind(hdc.bind(memory.role_range, range_lv))
  |> hdc.bind(hdc.bind(memory.role_slope, slope_lv))
  |> hdc.bind(hdc.bind(memory.role_energy, energy_lv))
}

/// Classify using k-NN: initial prototypes (weight 0.3) + learned exemplars (weight 1.0)
pub fn classify(
  memory: DynamicHdcMemory,
  query_hv: HyperVector,
) -> #(PlantState, List(#(PlantState, Float))) {
  let all_states = [Resting, Calm, Active, Transition, Stimulus, Stress]

  // Compute per-state scores
  let state_scores =
    list.map(all_states, fn(state) {
      // Initial prototype similarity (weight 0.3)
      let proto_sim = case
        list.find(memory.initial_prototypes, fn(p) { p.0 == state })
      {
        Ok(#(_, proto)) -> hdc.similarity(query_hv, proto) *. 0.3
        Error(_) -> 0.0
      }

      // Learned exemplar similarities (weight 1.0, take max)
      let state_exemplars =
        list.filter(memory.exemplars, fn(e) { e.state == state })
      let learned_sim = case state_exemplars {
        [] -> 0.0
        exs ->
          list.fold(exs, 0.0, fn(acc, e) {
            let sim = hdc.similarity(query_hv, e.hv)
            case sim >. acc {
              True -> sim
              False -> acc
            }
          })
      }

      // Blend: if no learned data, use proto only; otherwise max of both
      let score = case list.length(state_exemplars) {
        0 -> proto_sim
        _ -> {
          let blended = float.max(proto_sim, learned_sim)
          blended
        }
      }

      #(state, score)
    })

  // Find best state
  let best =
    list.fold(state_scores, #(Unknown, 0.0), fn(acc, item) {
      case item.1 >. acc.1 {
        True -> #(item.0, item.1)
        False -> acc
      }
    })

  #(best.0, state_scores)
}

/// Add a labeled exemplar (online learning)
pub fn learn(
  memory: DynamicHdcMemory,
  hv: HyperVector,
  state: PlantState,
  timestamp: Float,
) -> DynamicHdcMemory {
  let new_exemplar = Exemplar(hv:, state:, timestamp:)

  // Count existing exemplars for this state
  let state_count =
    list.filter(memory.exemplars, fn(e) { e.state == state })
    |> list.length

  // If at capacity, remove oldest for this state
  let trimmed = case state_count >= memory.max_per_state {
    True -> {
      // Find and remove the first (oldest) exemplar of this state
      remove_oldest_for_state(memory.exemplars, state)
    }
    False -> memory.exemplars
  }

  DynamicHdcMemory(..memory, exemplars: [new_exemplar, ..trimmed])
}

/// Remove oldest exemplar for a specific state
fn remove_oldest_for_state(
  exemplars: List(Exemplar),
  state: PlantState,
) -> List(Exemplar) {
  let reversed = list.reverse(exemplars)
  let filtered = remove_first_matching(reversed, state)
  list.reverse(filtered)
}

fn remove_first_matching(
  exemplars: List(Exemplar),
  state: PlantState,
) -> List(Exemplar) {
  case exemplars {
    [] -> []
    [first, ..rest] ->
      case first.state == state {
        True -> rest
        False -> [first, ..remove_first_matching(rest, state)]
      }
  }
}

/// Auto-calibrate: first 60 samples labeled as RESTING
pub fn auto_calibrate(
  memory: DynamicHdcMemory,
  hv: HyperVector,
  sample_count: Int,
  timestamp: Float,
) -> DynamicHdcMemory {
  case sample_count < calibration_samples && !memory.calibration_complete {
    True -> {
      // Every 10th sample, add as RESTING exemplar
      let new_memory = case sample_count % 10 == 0 {
        True -> learn(memory, hv, Resting, timestamp)
        False -> memory
      }
      DynamicHdcMemory(..new_memory, sample_count: sample_count + 1)
    }
    False ->
      DynamicHdcMemory(
        ..memory,
        calibration_complete: True,
        sample_count: sample_count + 1,
      )
  }
}

/// Get exemplar counts per state
pub fn exemplar_counts(memory: DynamicHdcMemory) -> List(#(PlantState, Int)) {
  let all_states = [Resting, Calm, Active, Transition, Stimulus, Stress]
  list.map(all_states, fn(state) {
    let count =
      list.filter(memory.exemplars, fn(e) { e.state == state })
      |> list.length
    #(state, count)
  })
}

/// Convert PlantState to string
pub fn state_to_string(state: PlantState) -> String {
  case state {
    Resting -> "RESTING"
    Calm -> "CALM"
    Active -> "ACTIVE"
    Transition -> "TRANSITION"
    Stimulus -> "STIMULUS"
    Stress -> "STRESS"
    Unknown -> "???"
  }
}

/// Parse state from string
pub fn parse_state(s: String) -> Result(PlantState, Nil) {
  case string.uppercase(s) {
    "RESTING" -> Ok(Resting)
    "CALM" -> Ok(Calm)
    "ACTIVE" -> Ok(Active)
    "TRANSITION" -> Ok(Transition)
    "STIMULUS" -> Ok(Stimulus)
    "STRESS" -> Ok(Stress)
    _ -> Error(Nil)
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

/// Similarities as JSON value
pub fn similarities_to_json_value(sims: List(#(PlantState, Float))) -> json.Json {
  sims
  |> list.map(fn(s) { #(state_to_string(s.0), json.float(s.1)) })
  |> json.object
}

/// Learning stats as JSON value
pub fn learning_to_json_value(memory: DynamicHdcMemory) -> json.Json {
  let counts = exemplar_counts(memory)
  json.object([
    #("calibration_complete", json.bool(memory.calibration_complete)),
    #(
      "calibration_progress",
      json.int(int.min(memory.sample_count, calibration_samples)),
    ),
    #("calibration_total", json.int(calibration_samples)),
    #(
      "exemplars",
      json.object(
        list.map(counts, fn(c) { #(state_to_string(c.0), json.int(c.1)) }),
      ),
    ),
    #("total_labels", json.int(list.length(memory.exemplars))),
  ])
}
