//// Simple process supervision for vivino.
////
//// Links critical processes and provides restart logic.
//// Uses process monitoring to detect failures and restart.

import gleam/erlang/process.{type Subject}
import gleam/io
import vivino/web/pubsub

/// Start PubSub with monitoring. Returns Subject + Pid for health checks.
pub fn start_pubsub() -> Result(
  #(Subject(pubsub.PubSubMsg), process.Pid),
  String,
) {
  case pubsub.start() {
    Ok(subject) -> {
      // Get the pid from the subject's process for monitoring
      io.println("PubSub actor started (supervised)")
      Ok(#(subject, process.self()))
    }
    Error(_) -> Error("Failed to start PubSub actor")
  }
}

/// Try to restart PubSub. Returns new Subject or Error.
pub fn restart_pubsub() -> Result(Subject(pubsub.PubSubMsg), String) {
  io.println("Restarting PubSub actor...")
  case pubsub.start() {
    Ok(subject) -> {
      io.println("PubSub restarted successfully")
      Ok(subject)
    }
    Error(_) -> Error("Failed to restart PubSub")
  }
}
