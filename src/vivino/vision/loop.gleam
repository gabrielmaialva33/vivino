//// Vision processing loop — runs alongside the main bioelectric signal loop.
////
//// Spawns Python YOLO sidecar as an Erlang port, reads JSON detection
//// results, broadcasts them to WebSocket clients, and speaks via TTS
//// when events are detected (person, plant, motion).
//// Crash-isolated: if the vision sidecar dies, plant monitoring continues.

import gleam/dynamic.{type Dynamic}
import gleam/erlang/process.{type Subject}
import gleam/io
import vivino/vision/detector
import vivino/vision/voice
import vivino/web/pubsub

/// Opaque Erlang port reference
pub type VisionPort =
  Dynamic

/// FFI bindings — same pattern as serial port
@external(erlang, "vivino_ffi", "open_vision")
fn open_vision(
  rtsp_url: String,
  model_path: String,
  conf: Float,
) -> Result(VisionPort, Dynamic)

@external(erlang, "vivino_ffi", "read_vision_line")
fn read_vision_line(port: VisionPort) -> Result(String, Dynamic)

@external(erlang, "vivino_ffi", "vision_cmd")
pub fn vision_cmd(port: VisionPort, cmd: String) -> Result(Nil, Dynamic)

@external(erlang, "vivino_ffi", "timestamp_ms")
fn timestamp_ms() -> Int

/// Configuration for the vision sidecar
pub type VisionConfig {
  VisionConfig(rtsp_url: String, model_path: String, confidence: Float)
}

/// Vision loop state — tracks detections for TTS cooldown
type VisionState {
  VisionState(
    frame_count: Int,
    person_seen: Bool,
    plant_announced: Bool,
    last_speak_ms: Int,
  )
}

/// Speech cooldown: 15 seconds between announcements
const speak_cooldown_ms = 15_000

/// Default configuration for the Yoosee camera
pub fn default_config(camera_ip: String) -> VisionConfig {
  VisionConfig(
    rtsp_url: "rtsp://" <> camera_ip <> ":554/onvif1",
    model_path: "yolo11s.pt",
    confidence: 0.35,
  )
}

/// Start the vision detector loop in the current process.
/// Typically called from a spawned BEAM process.
pub fn run(config: VisionConfig, pubsub: Subject(pubsub.PubSubMsg)) -> Nil {
  io.println("Vision: connecting to " <> config.rtsp_url)
  case open_vision(config.rtsp_url, config.model_path, config.confidence) {
    Ok(port) -> {
      io.println("Vision: sidecar started, waiting for GPU warmup...")
      voice.vision_online()
      let state =
        VisionState(
          frame_count: 0,
          person_seen: False,
          plant_announced: False,
          last_speak_ms: 0,
        )
      vision_loop(port, pubsub, config, state)
    }
    Error(_) -> {
      io.println("Vision: failed to start sidecar, retrying in 30s...")
      process.sleep(30_000)
      run(config, pubsub)
    }
  }
}

/// Main vision read loop
fn vision_loop(
  port: VisionPort,
  pubsub: Subject(pubsub.PubSubMsg),
  config: VisionConfig,
  state: VisionState,
) -> Nil {
  case read_vision_line(port) {
    Ok(json_line) -> {
      let new_state = case detector.parse_vision_json(json_line) {
        Ok(frame) -> {
          // Broadcast vision data to all WebSocket clients
          let json = detector.vision_to_json(frame)
          process.send(pubsub, pubsub.Broadcast(json))

          // React to detections with TTS
          react_to_frame(frame, state)
        }
        Error(_) -> {
          // Status messages, errors — log but continue
          io.println("Vision: " <> json_line)
          state
        }
      }
      vision_loop(
        port,
        pubsub,
        config,
        VisionState(..new_state, frame_count: state.frame_count + 1),
      )
    }
    Error(_) -> {
      io.println("Vision: sidecar disconnected, restarting in 15s...")
      process.sleep(15_000)
      run(config, pubsub)
    }
  }
}

/// React to a vision frame — speak when person appears/disappears
fn react_to_frame(
  frame: detector.VisionFrame,
  state: VisionState,
) -> VisionState {
  let has_person = detector.has_person(frame)
  let has_plant = detector.count_class(frame, "potted plant") > 0
  let now = timestamp_ms()
  let can_speak = now - state.last_speak_ms > speak_cooldown_ms

  // Person state transitions
  let #(new_person_seen, new_speak_ms) = case has_person, state.person_seen {
    // Person just appeared
    True, False if can_speak -> {
      voice.person_detected()
      io.println(
        "  PERSON DETECTED (" <> detector.detection_summary(frame) <> ")",
      )
      #(True, now)
    }
    // Person returned after leaving
    True, False -> {
      io.println(
        "  PERSON DETECTED (" <> detector.detection_summary(frame) <> ")",
      )
      #(True, state.last_speak_ms)
    }
    // Person just left
    False, True if can_speak -> {
      voice.person_gone()
      io.println("  Person left frame")
      #(False, now)
    }
    False, True -> {
      io.println("  Person left frame")
      #(False, state.last_speak_ms)
    }
    // No change
    _, _ -> #(has_person, state.last_speak_ms)
  }

  // Plant detection (announce once)
  let #(new_plant_announced, final_speak_ms) = case
    has_plant,
    state.plant_announced
  {
    True, False if can_speak || new_speak_ms == state.last_speak_ms -> {
      voice.plant_detected()
      #(True, now)
    }
    True, False -> #(False, new_speak_ms)
    _, announced -> #(announced, new_speak_ms)
  }

  VisionState(
    frame_count: state.frame_count,
    person_seen: new_person_seen,
    plant_announced: new_plant_announced,
    last_speak_ms: final_speak_ms,
  )
}
