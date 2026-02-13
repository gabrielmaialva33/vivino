//// Terminal display output for vivino.

import gleam/float
import gleam/int
import gleam/io
import gleam/list
import gleam/string
import gleam/yielder
import vivino/serial/parser.{type Reading}
import vivino/signal/features.{type SignalFeatures}
import vivino/signal/learner

/// Print startup header
pub fn header() {
  io.println("")
  io.println("╔═══════════════════════════════════════════╗")
  io.println("║   VIVINO - Plant Bioelectric Monitor      ║")
  io.println("║   viva_tensor + CUDA GPU + WebSocket       ║")
  io.println("╚═══════════════════════════════════════════╝")
  io.println("")
}

/// Print a reading
pub fn reading(r: Reading) {
  io.println(
    "["
    <> fstr(r.elapsed)
    <> "s] raw:"
    <> int.to_string(r.raw)
    <> " mv:"
    <> fstr(r.mv)
    <> " dev:"
    <> fstr(r.deviation)
    <> "mV",
  )
}

/// Print extracted features
pub fn print_features(f: SignalFeatures, state: String) {
  io.println(
    "  Features: mean="
    <> fstr(f.mean)
    <> " std="
    <> fstr(f.std)
    <> " range="
    <> fstr(f.range)
    <> " slope="
    <> fstr(f.slope)
    <> " rms="
    <> fstr(f.rms)
    <> " dv/dt="
    <> fstr(f.dvdt_max)
    <> " skew="
    <> fstr(f.skewness)
    <> " kurt="
    <> fstr(f.kurtosis)
    <> " peaks="
    <> fstr(f.peak_count),
  )
  io.println("  State: " <> state)
}

/// Print HDC learner similarities
pub fn print_hdc_learner(sims: List(#(learner.PlantState, Float)), best: String) {
  let sim_str =
    sims
    |> list.map(fn(s) { learner.state_to_string(s.0) <> ":" <> pct(s.1) })
    |> string.join(" ")

  io.println("  HDC: " <> sim_str <> " -> " <> best)
}

/// Print GPU classifier results
pub fn print_gpu(results: List(#(String, Float)), best: String) {
  let sim_str =
    results
    |> list.map(fn(r) { r.0 <> ":" <> pct(r.1) })
    |> string.join(" ")

  io.println("  GPU: " <> sim_str <> " -> " <> best)
}

/// Print separator
pub fn separator() {
  io.println(string.repeat("─", 50))
}

/// Deviation bar (ASCII)
pub fn deviation_bar(deviation: Float) -> String {
  let clamped = float.clamp(deviation, -100.0, 100.0)
  let pos = float.round({ clamped +. 100.0 } /. 4.0)
  let width = 50

  let bar =
    yielder.range(from: 0, to: width - 1)
    |> yielder.to_list
    |> list.map(fn(i) {
      case i == width / 2 {
        True -> "|"
        False ->
          case i == pos {
            True -> "#"
            False -> "."
          }
      }
    })
    |> string.join("")

  "-100mV " <> bar <> " +100mV"
}

// Helpers
fn fstr(f: Float) -> String {
  let rounded = int.to_float(float.round(f *. 10.0)) /. 10.0
  float.to_string(rounded)
}

fn pct(f: Float) -> String {
  let p = float.round(f *. 1000.0) |> int.to_float
  float.to_string(p /. 10.0) <> "%"
}
