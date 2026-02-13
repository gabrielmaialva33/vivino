//// VIVINO - Real-time plant bioelectric intelligence
////
//// Pipeline: Arduino → IQR cleaning → 27 features → quality check →
//// HDC temporal encoding → dual AI classify → novelty detection →
//// temporal smoothing → pseudo-labeling → online learning → dashboard
////
//// State-of-the-art techniques from LifeHD, TorchHD, HDC-EMG, SIGNET.
////
//// Usage:
////   gleam run                              # auto-detects serial port
////   VIVINO_ORGANISM=cannabis gleam run     # cannabis profile
////   echo "data" | gleam run               # pipe mode (stdin fallback)

import gleam/erlang/process
import gleam/io
import gleam/json
import gleam/list
import gleam/result
import vivino/display

@external(erlang, "vivino_ffi", "get_env")
fn get_env(name: String) -> Result(String, Nil)

import vivino/serial/parser
import vivino/serial/port
import vivino/signal/dynamic_gpu
import vivino/signal/features
import vivino/signal/label_bridge
import vivino/signal/learner
import vivino/signal/profile
import vivino/web/pubsub
import vivino/web/server

/// Analysis window size (50 samples @ 20Hz = 2.5s window)
const window_size = 50

/// WebSocket server port
const web_port = 3000

/// Min samples between pseudo-labels (rate limiting)
const pseudo_label_cooldown = 20

/// Processing state carried through the loop
type LoopState {
  LoopState(
    hdc: learner.DynamicHdcMemory,
    gpu: Result(dynamic_gpu.DynamicGpuClassifier, String),
    profile: profile.OrganismProfile,
    pubsub: process.Subject(pubsub.PubSubMsg),
    buffer: List(parser.Reading),
    sample_count: Int,
    temporal_ctx: learner.TemporalContext,
    pseudo_label_count: Int,
    last_pseudo_label_sample: Int,
  )
}

pub fn main() {
  display.header()

  // 1. Select organism from env var
  let organism =
    get_env("VIVINO_ORGANISM")
    |> result.try(profile.parse_organism)
    |> result.unwrap(profile.Shimeji)
  let prof = profile.get_profile(organism)
  io.println("Organism: " <> prof.display_name <> " [" <> prof.name <> "]")

  // Store organism for label_bridge
  let _ = label_bridge.put_organism(prof.name)

  // 2. Start PubSub actor
  let assert Ok(pubsub_subject) = pubsub.start()
  io.println("PubSub actor started")

  // 3. Start HTTP + WebSocket server
  case server.start(pubsub_subject, web_port) {
    Ok(_) -> Nil
    Error(msg) -> io.println("Warning: " <> msg)
  }

  // 4. Initialize dynamic GPU classifier (OnlineHD adaptive alpha)
  let gpu_state = case dynamic_gpu.init(prof) {
    Ok(g) -> {
      io.println("GPU classifier initialized (" <> prof.name <> " profile)")
      Ok(g)
    }
    Error(e) -> {
      io.println("GPU init failed: " <> e <> " (using HDC fallback)")
      Error(e)
    }
  }

  // 5. Initialize dynamic HDC memory (novelty + temporal + cutting angle)
  let hdc_memory = learner.init(prof)
  io.println(
    "HDC learner ready (10,048 dims, k-NN, temporal n-gram, novelty, cutting angle)",
  )
  display.separator()

  let state =
    LoopState(
      hdc: hdc_memory,
      gpu: gpu_state,
      profile: prof,
      pubsub: pubsub_subject,
      buffer: [],
      sample_count: 0,
      temporal_ctx: learner.init_temporal_context(5),
      pseudo_label_count: 0,
      last_pseudo_label_sample: 0,
    )

  // 6. Open serial port directly
  case port.auto_open() {
    Ok(serial) -> {
      io.println("Reading from serial port...")
      io.println("")
      serial_loop(state, serial)
    }
    Error(msg) -> {
      io.println("Serial: " <> msg)
      io.println("Falling back to stdin (pipe mode)...")
      io.println("")
      stdin_loop(state)
    }
  }
}

/// Main processing loop: serial port
fn serial_loop(state: LoopState, serial: port.SerialPort) {
  case port.read_port_line(serial) {
    Ok(line) -> {
      let new_state = process_line(line, state)
      serial_loop(new_state, serial)
    }
    Error(_) -> {
      io.println("")
      io.println("Serial port closed.")
      Nil
    }
  }
}

/// Fallback loop: stdin
fn stdin_loop(state: LoopState) {
  case port.read_line() {
    Ok(line) -> {
      let new_state = process_line(line, state)
      stdin_loop(new_state)
    }
    Error(_) -> {
      io.println("")
      io.println("End of input.")
      Nil
    }
  }
}

/// Full processing pipeline per sample:
/// 1. Parse → 2. IQR clean → 3. Extract features → 4. Quality check →
/// 5. HDC encode → 6. Temporal encode → 7. Classify → 8. Novelty →
/// 9. Temporal smooth → 10. Label/pseudo-label → 11. Learn → 12. Broadcast
fn process_line(line: String, state: LoopState) -> LoopState {
  case parser.parse_line(line) {
    parser.DataLine(reading) -> {
      display.reading(reading)

      // Sliding window
      let trimmed = [reading, ..state.buffer] |> list.take(window_size)
      let buf_len = list.length(trimmed)
      let new_count = state.sample_count + 1

      case buf_len >= 10 {
        True -> {
          // [1] IQR outlier cleaning (SIGNET)
          let samples = list.reverse(trimmed)
          let cleaned = features.clean_outliers(samples)

          // [2] Extract 27 features from cleaned signal
          let feats = features.extract(cleaned)

          // [3] Signal quality assessment (SIGNET)
          let quality = features.assess_quality(feats)

          let rule_state =
            features.classify_state_with(feats, state.profile.thresholds)
          display.print_features(feats, rule_state)
          display.print_quality(quality)

          // [4] GPU classification (OnlineHD adaptive)
          let #(gpu_state_str, gpu_sims, new_gpu) = case state.gpu {
            Ok(g) -> {
              let #(s, sims) = dynamic_gpu.classify(g, feats)
              #(s, sims, Ok(g))
            }
            Error(e) -> #("???", [], Error(e))
          }
          display.print_gpu(gpu_sims, gpu_state_str)

          // [5] HDC encode with profile ranges
          let base_hv =
            learner.encode(state.hdc, feats, state.profile.quant_ranges)

          // [6] N-gram temporal encoding (HDC-EMG)
          let #(temporal_hv, hdc_with_temporal) =
            learner.encode_temporal(state.hdc, base_hv)

          // [7] Auto-calibration (first 60 samples → RESTING)
          let hdc_after_cal =
            learner.auto_calibrate(
              hdc_with_temporal,
              temporal_hv,
              new_count,
              reading.elapsed,
            )

          // [8] Classify with novelty detection (LifeHD)
          let #(hdc_state, hdc_sims, novelty) =
            learner.classify(hdc_after_cal, temporal_hv)

          // [9] Update state stats for novelty tracking
          let hdc_with_stats =
            learner.update_stats(hdc_after_cal, hdc_state, novelty.score)

          // [10] Temporal context smoothing (majority vote)
          let new_temporal_ctx =
            learner.update_temporal_context(state.temporal_ctx, hdc_state)
          let _smoothed = learner.smoothed_state(new_temporal_ctx)

          display.print_hdc_learner(
            hdc_sims,
            learner.state_to_string(hdc_state),
          )
          display.print_novelty(novelty.is_novel, novelty.score)
          display.separator()

          // [11] User labels from dashboard
          let #(after_label_hdc, after_label_gpu) = case
            label_bridge.get_label()
          {
            Ok(label_str) -> {
              case learner.parse_state(label_str) {
                Ok(label_state) -> {
                  io.println(
                    "  LEARN: labeled as "
                    <> learner.state_to_string(label_state),
                  )
                  let learned_hdc =
                    learner.learn(
                      hdc_with_stats,
                      temporal_hv,
                      label_state,
                      reading.elapsed,
                    )
                  let learned_gpu = case new_gpu {
                    Ok(g) -> Ok(dynamic_gpu.learn(g, feats, label_str))
                    Error(e) -> Error(e)
                  }
                  #(learned_hdc, learned_gpu)
                }
                Error(_) -> #(hdc_with_stats, new_gpu)
              }
            }
            Error(_) -> #(hdc_with_stats, new_gpu)
          }

          // [12] Pseudo-labeling (LifeHD semi-supervised)
          let #(final_hdc, final_gpu, new_pseudo_count, new_last_pseudo) = case
            quality.is_good && !novelty.is_novel
          {
            True ->
              case
                try_pseudo_label(
                  hdc_state,
                  hdc_sims,
                  gpu_state_str,
                  gpu_sims,
                  new_count,
                  state.last_pseudo_label_sample,
                )
              {
                Ok(pseudo_state) -> {
                  let p_hdc =
                    learner.learn(
                      after_label_hdc,
                      temporal_hv,
                      pseudo_state,
                      reading.elapsed,
                    )
                  let p_gpu = case after_label_gpu {
                    Ok(g) ->
                      Ok(dynamic_gpu.learn(
                        g,
                        feats,
                        learner.state_to_string(pseudo_state),
                      ))
                    Error(e) -> Error(e)
                  }
                  #(p_hdc, p_gpu, state.pseudo_label_count + 1, new_count)
                }
                Error(_) -> #(
                  after_label_hdc,
                  after_label_gpu,
                  state.pseudo_label_count,
                  state.last_pseudo_label_sample,
                )
              }
            False -> #(
              after_label_hdc,
              after_label_gpu,
              state.pseudo_label_count,
              state.last_pseudo_label_sample,
            )
          }

          // [13] Build and broadcast JSON
          let json_str =
            build_json(
              reading,
              feats,
              rule_state,
              gpu_state_str,
              gpu_sims,
              hdc_state,
              hdc_sims,
              state.profile,
              final_hdc,
              quality,
              novelty,
              new_pseudo_count,
            )
          process.send(state.pubsub, pubsub.Broadcast(json_str))

          LoopState(
            ..state,
            hdc: final_hdc,
            gpu: final_gpu,
            buffer: trimmed,
            sample_count: new_count,
            temporal_ctx: new_temporal_ctx,
            pseudo_label_count: new_pseudo_count,
            last_pseudo_label_sample: new_last_pseudo,
          )
        }
        False -> {
          let json_str = parser.reading_to_json(reading)
          process.send(state.pubsub, pubsub.Broadcast(json_str))
          LoopState(..state, buffer: trimmed, sample_count: new_count)
        }
      }
    }
    parser.StimLine(stim) -> {
      io.println(
        "STIM: "
        <> stim.protocol
        <> " "
        <> stim.count
        <> " "
        <> stim.stim_type
        <> " "
        <> stim.duration,
      )
      let json_str = parser.stim_to_json(stim)
      process.send(state.pubsub, pubsub.Broadcast(json_str))
      state
    }
    _ -> state
  }
}

/// Try pseudo-labeling: both classifiers must agree with high confidence
fn try_pseudo_label(
  hdc_state: learner.PlantState,
  hdc_sims: List(#(learner.PlantState, Float)),
  gpu_state_str: String,
  gpu_sims: List(#(String, Float)),
  current_sample: Int,
  last_pseudo_sample: Int,
) -> Result(learner.PlantState, Nil) {
  let hdc_str = learner.state_to_string(hdc_state)

  // Both classifiers agree?
  case hdc_str == gpu_state_str {
    False -> Error(Nil)
    True -> {
      // Rate limit: cooldown between pseudo-labels
      case current_sample - last_pseudo_sample >= pseudo_label_cooldown {
        False -> Error(Nil)
        True -> {
          // GPU confidence > 0.6?
          let gpu_conf =
            list.find(gpu_sims, fn(s) { s.0 == gpu_state_str })
            |> result.map(fn(s) { s.1 })
            |> result.unwrap(0.0)

          // HDC similarity > 0.4?
          let hdc_conf =
            list.find(hdc_sims, fn(s) { s.0 == hdc_state })
            |> result.map(fn(s) { s.1 })
            |> result.unwrap(0.0)

          case gpu_conf >. 0.6 && hdc_conf >. 0.4 {
            True -> Ok(hdc_state)
            False -> Error(Nil)
          }
        }
      }
    }
  }
}

/// Build full JSON payload with quality, novelty, and pseudo-label stats
fn build_json(
  r: parser.Reading,
  f: features.SignalFeatures,
  state: String,
  gpu_state_str: String,
  gpu_sims: List(#(String, Float)),
  hdc_state: learner.PlantState,
  hdc_sims: List(#(learner.PlantState, Float)),
  prof: profile.OrganismProfile,
  hdc_memory: learner.DynamicHdcMemory,
  quality: features.SignalQuality,
  novelty: learner.NoveltyInfo,
  pseudo_count: Int,
) -> String {
  json.object([
    #("elapsed", json.float(r.elapsed)),
    #("raw", json.int(r.raw)),
    #("mv", json.float(r.mv)),
    #("deviation", json.float(r.deviation)),
    #("state", json.string(state)),
    #("organism", json.string(prof.name)),
    #("organism_display", json.string(prof.display_name)),
    #("gpu_state", json.string(gpu_state_str)),
    #("gpu", dynamic_gpu.results_to_json_value(gpu_sims)),
    #("hdc_state", json.string(learner.state_to_string(hdc_state))),
    #("hdc", learner.similarities_to_json_value(hdc_sims)),
    #("features", features.to_json_value(f)),
    #("learning", learner.learning_to_json_value(hdc_memory)),
    #("quality", features.quality_to_json_value(quality)),
    #("novelty", learner.novelty_to_json_value(novelty)),
    #("pseudo_labels", json.int(pseudo_count)),
  ])
  |> json.to_string
}
