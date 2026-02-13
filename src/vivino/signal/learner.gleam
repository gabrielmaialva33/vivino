//// Dynamic HDC classifier with state-of-the-art online learning.
////
//// Hyperdimensional computing with k-NN exemplar classification,
//// n-gram temporal encoding, novelty detection, cutting angle
//// redundancy filtering, and temporal context smoothing.
////
//// Inspired by: LifeHD (novelty), TorchHD (OnlineHD),
//// HDC-EMG (temporal + cutting angle), SIGNET (quality).
////
//// No bundle operation needed — pure similarity-based.

import gleam/float
import gleam/int
import gleam/json
import gleam/list
import gleam/result
import gleam/string
import gleam/yielder
import viva_tensor/hdc.{type HyperVector}
import vivino/signal/features.{type SignalFeatures}
import vivino/signal/profile.{type OrganismProfile, type QuantRanges}

// ============================================
// Types
// ============================================

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

/// Per-state similarity statistics for novelty detection (LifeHD)
pub type StateStats {
  StateStats(mean_sim: Float, var_sim: Float, count: Int)
}

/// Novelty detection result
pub type NoveltyInfo {
  NoveltyInfo(is_novel: Bool, score: Float, threshold: Float)
}

/// Temporal context buffer for majority-vote smoothing
pub type TemporalContext {
  TemporalContext(history: List(PlantState), depth: Int)
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
    // Novelty detection: per-state similarity stats
    state_stats: List(#(PlantState, StateStats)),
    // N-gram temporal encoding: recent HV history
    recent_hvs: List(HyperVector),
    // Cutting angle: redundancy rejection counter
    learning_rejected: Int,
  )
}

// ============================================
// Constants
// ============================================

/// Hypervector dimensionality
const dim = 10_048

/// Number of quantization levels
const num_levels = 16

/// Samples for auto-calibration (3s @ 20Hz)
const calibration_samples = 60

/// Max exemplars per state in ring buffer
const default_max_per_state = 5

/// Cutting angle threshold — reject if similarity > this
const cutting_angle_threshold = 0.85

/// Novelty detection gamma (σ multiplier)
const novelty_gamma = 1.5

/// EMA decay for state stats
const stats_decay = 0.95

/// Minimum observations before novelty detection activates
const novelty_min_count = 5

// ============================================
// Initialization
// ============================================

/// Initialize dynamic HDC memory from an organism profile
pub fn init(_profile: OrganismProfile) -> DynamicHdcMemory {
  let all_states = [Resting, Calm, Active, Transition, Stimulus, Stress]

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

  // Initialize per-state stats for novelty detection
  let state_stats =
    list.map(all_states, fn(s) {
      #(s, StateStats(mean_sim: 0.5, var_sim: 0.01, count: 0))
    })

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
    state_stats:,
    recent_hvs: [],
    learning_rejected: 0,
  )
}

// ============================================
// Encoding
// ============================================

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

/// N-gram temporal encoding: bind current HV with permuted history
///
/// Creates temporal context by XOR-binding the current hypervector
/// with circularly-shifted versions of recent HVs (HDC-EMG approach).
/// Permute(hv, k) shifts bits by k positions — encodes temporal position.
pub fn encode_temporal(
  memory: DynamicHdcMemory,
  current_hv: HyperVector,
) -> #(HyperVector, DynamicHdcMemory) {
  let recent = [current_hv, ..memory.recent_hvs] |> list.take(3)

  let temporal_hv = case recent {
    // Empty — shouldn't happen but handle gracefully
    [] -> current_hv
    // Only current — no temporal context yet
    [_] -> current_hv
    // Current + 1 previous: bind with t-1 shifted by 1
    [_, prev, ..] -> {
      let shifted = hdc.permute(prev, 1)
      hdc.bind(current_hv, shifted)
    }
  }

  // If we have 3+ HVs, also bind t-2 shifted by 2
  let temporal_hv2 = case recent {
    [_, _, prev2, ..] -> {
      let shifted2 = hdc.permute(prev2, 2)
      hdc.bind(temporal_hv, shifted2)
    }
    _ -> temporal_hv
  }

  #(temporal_hv2, DynamicHdcMemory(..memory, recent_hvs: recent))
}

// ============================================
// Classification + Novelty Detection
// ============================================

/// Classify with k-NN + novelty detection (LifeHD-inspired)
///
/// Returns: (best_state, per_state_scores, novelty_info)
/// Novelty = when the best similarity falls below μ - γσ̂ for that state
pub fn classify(
  memory: DynamicHdcMemory,
  query_hv: HyperVector,
) -> #(PlantState, List(#(PlantState, Float)), NoveltyInfo) {
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
            float.max(acc, sim)
          })
      }

      // Blend: if no learned data, use proto only; otherwise max of both
      let score = case list.length(state_exemplars) {
        0 -> proto_sim
        _ -> float.max(proto_sim, learned_sim)
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

  // Novelty detection: check if best sim is below expected range
  let novelty = compute_novelty(memory, best.0, best.1)

  #(best.0, state_scores, novelty)
}

/// Compute novelty info for the winning state
fn compute_novelty(
  memory: DynamicHdcMemory,
  state: PlantState,
  best_sim: Float,
) -> NoveltyInfo {
  case list.find(memory.state_stats, fn(s) { s.0 == state }) {
    Ok(#(_, stats)) -> {
      let std_sim =
        float.square_root(float.max(stats.var_sim, 0.0))
        |> result.unwrap(0.0)
      let threshold = stats.mean_sim -. novelty_gamma *. std_sim
      let is_novel = best_sim <. threshold && stats.count > novelty_min_count
      NoveltyInfo(is_novel:, score: best_sim, threshold:)
    }
    Error(_) -> NoveltyInfo(is_novel: False, score: best_sim, threshold: 0.0)
  }
}

/// Update state stats after classification (EMA on similarity)
pub fn update_stats(
  memory: DynamicHdcMemory,
  state: PlantState,
  sim: Float,
) -> DynamicHdcMemory {
  let new_stats =
    list.map(memory.state_stats, fn(entry) {
      case entry.0 == state {
        True -> {
          let stats = entry.1
          let new_mean =
            stats_decay *. stats.mean_sim +. { 1.0 -. stats_decay } *. sim
          let diff = sim -. new_mean
          let new_var =
            stats_decay
            *. stats.var_sim
            +. { 1.0 -. stats_decay }
            *. diff
            *. diff
          #(
            state,
            StateStats(
              mean_sim: new_mean,
              var_sim: new_var,
              count: stats.count + 1,
            ),
          )
        }
        False -> entry
      }
    })
  DynamicHdcMemory(..memory, state_stats: new_stats)
}

// ============================================
// Learning with Cutting Angle Filter
// ============================================

/// Check if a new exemplar is sufficiently different (HDC-EMG cutting angle)
fn passes_cutting_angle(
  memory: DynamicHdcMemory,
  hv: HyperVector,
  state: PlantState,
) -> Bool {
  let state_exemplars =
    list.filter(memory.exemplars, fn(e) { e.state == state })
  case state_exemplars {
    [] -> True
    exs -> {
      let max_sim =
        list.fold(exs, 0.0, fn(acc, e) {
          float.max(acc, hdc.similarity(hv, e.hv))
        })
      max_sim <. cutting_angle_threshold
    }
  }
}

/// Add a labeled exemplar with cutting angle redundancy filter
pub fn learn(
  memory: DynamicHdcMemory,
  hv: HyperVector,
  state: PlantState,
  timestamp: Float,
) -> DynamicHdcMemory {
  // Cutting angle filter: reject if too similar to existing exemplars
  case passes_cutting_angle(memory, hv, state) {
    False ->
      DynamicHdcMemory(
        ..memory,
        learning_rejected: memory.learning_rejected + 1,
      )
    True -> {
      let new_exemplar = Exemplar(hv:, state:, timestamp:)

      // Count existing exemplars for this state
      let state_count =
        list.filter(memory.exemplars, fn(e) { e.state == state })
        |> list.length

      // If at capacity, remove oldest for this state
      let trimmed = case state_count >= memory.max_per_state {
        True -> remove_oldest_for_state(memory.exemplars, state)
        False -> memory.exemplars
      }

      DynamicHdcMemory(..memory, exemplars: [new_exemplar, ..trimmed])
    }
  }
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

// ============================================
// Auto-calibration
// ============================================

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

// ============================================
// Temporal Context (Majority Vote Smoothing)
// ============================================

/// Initialize temporal context buffer
pub fn init_temporal_context(depth: Int) -> TemporalContext {
  TemporalContext(history: [], depth:)
}

/// Add a state to the temporal context
pub fn update_temporal_context(
  ctx: TemporalContext,
  state: PlantState,
) -> TemporalContext {
  let history = [state, ..ctx.history] |> list.take(ctx.depth)
  TemporalContext(..ctx, history:)
}

/// Get smoothed state via majority vote over history
pub fn smoothed_state(ctx: TemporalContext) -> PlantState {
  case ctx.history {
    [] -> Unknown
    _ -> {
      let all_states = [Resting, Calm, Active, Transition, Stimulus, Stress]
      let counts =
        list.map(all_states, fn(s) {
          let c =
            list.filter(ctx.history, fn(h) { h == s })
            |> list.length
          #(s, c)
        })
      let best =
        list.fold(counts, #(Unknown, 0), fn(acc, item) {
          case item.1 > acc.1 {
            True -> item
            False -> acc
          }
        })
      best.0
    }
  }
}

// ============================================
// Stats & Serialization
// ============================================

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

/// Novelty info as JSON value
pub fn novelty_to_json_value(info: NoveltyInfo) -> json.Json {
  json.object([
    #("is_novel", json.bool(info.is_novel)),
    #("score", json.float(info.score)),
    #("threshold", json.float(info.threshold)),
  ])
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
    #("rejected", json.int(memory.learning_rejected)),
  ])
}
