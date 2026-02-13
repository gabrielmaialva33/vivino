//// NF4 compression for long-term session storage.
////
//// Compresses bioelectric data with ~7.5x ratio using NF4 quantization.

import gleam/float
import gleam/int
import gleam/list
import viva_tensor as t
import viva_tensor/quant/nf4
import vivino/serial/parser.{type Reading}

/// Compressed session data
pub type CompressedSession {
  CompressedSession(
    samples: Int,
    duration_s: Float,
    compressed: nf4.NF4Tensor,
    mean_mv: Float,
    std_mv: Float,
  )
}

/// Compress a list of readings to NF4
pub fn compress(readings: List(Reading)) -> CompressedSession {
  let values = list.map(readings, fn(r) { r.mv })
  let tensor = t.from_list(values)

  let mean = t.mean(tensor)
  let std = t.std(tensor)
  let n = list.length(readings)

  let duration = case readings {
    [] -> 0.0
    [first, ..rest] ->
      case list.last(rest) {
        Ok(last) -> last.elapsed -. first.elapsed
        Error(_) -> 0.0
      }
  }

  let config = nf4.default_config()
  let compressed = nf4.quantize(tensor, config)

  CompressedSession(
    samples: n,
    duration_s: duration,
    compressed:,
    mean_mv: mean,
    std_mv: std,
  )
}

/// Decompress session for analysis
pub fn decompress(session: CompressedSession) -> t.Tensor {
  nf4.dequantize(session.compressed)
}

/// Format session info
pub fn format(session: CompressedSession) -> String {
  let mins = session.duration_s /. 60.0
  "Session: "
  <> int.to_string(session.samples)
  <> " samples | "
  <> float.to_string(round1(mins))
  <> " min | Mean: "
  <> float.to_string(float.round(session.mean_mv) |> int.to_float)
  <> "mV | NF4: "
  <> int.to_string(session.compressed.memory_bytes)
  <> " bytes ("
  <> float.to_string(session.compressed.compression_ratio)
  <> "x)"
}

fn round1(f: Float) -> Float {
  int.to_float(float.round(f *. 10.0)) /. 10.0
}
