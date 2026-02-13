//// PubSub actor for broadcasting readings to WebSocket clients.
////
//// Central message bus: serial reader publishes, WS clients subscribe.
//// Automatically cleans up dead subscribers on broadcast.

import gleam/erlang/process.{type Subject}
import gleam/int
import gleam/io
import gleam/list
import gleam/otp/actor

/// Type alias for convenience
pub type PubSubSubject =
  Subject(PubSubMsg)

/// Messages for the PubSub actor
pub type PubSubMsg {
  Subscribe(Subject(String))
  Unsubscribe(Subject(String))
  Broadcast(String)
  GetStats(Subject(PubSubStats))
}

/// Stats for monitoring
pub type PubSubStats {
  PubSubStats(subscribers: Int, total_broadcasts: Int)
}

/// PubSub state
pub type PubSubState {
  PubSubState(subscribers: List(Subject(String)), total_broadcasts: Int)
}

/// Start the PubSub actor
pub fn start() -> Result(PubSubSubject, actor.StartError) {
  let result =
    actor.new(PubSubState(subscribers: [], total_broadcasts: 0))
    |> actor.on_message(handle_message)
    |> actor.start

  case result {
    Ok(started) -> Ok(started.data)
    Error(e) -> Error(e)
  }
}

/// Handle PubSub messages
fn handle_message(
  state: PubSubState,
  msg: PubSubMsg,
) -> actor.Next(PubSubState, PubSubMsg) {
  case msg {
    Subscribe(sub) -> {
      // Avoid duplicate subscriptions
      let already = list.any(state.subscribers, fn(s) { s == sub })
      case already {
        True -> actor.continue(state)
        False -> {
          let n = list.length(state.subscribers) + 1
          io.println("Client connected (" <> int.to_string(n) <> " total)")
          actor.continue(
            PubSubState(..state, subscribers: [sub, ..state.subscribers]),
          )
        }
      }
    }

    Unsubscribe(sub) -> {
      let new_subs = list.filter(state.subscribers, fn(s) { s != sub })
      let n = list.length(new_subs)
      io.println("Client disconnected (" <> int.to_string(n) <> " remaining)")
      actor.continue(PubSubState(..state, subscribers: new_subs))
    }

    Broadcast(json) -> {
      // Send to all subscribers - process.send is fire-and-forget
      // on BEAM, dead subjects just drop the message silently
      list.each(state.subscribers, fn(sub) { process.send(sub, json) })
      actor.continue(
        PubSubState(..state, total_broadcasts: state.total_broadcasts + 1),
      )
    }

    GetStats(reply_to) -> {
      process.send(
        reply_to,
        PubSubStats(
          subscribers: list.length(state.subscribers),
          total_broadcasts: state.total_broadcasts,
        ),
      )
      actor.continue(state)
    }
  }
}
