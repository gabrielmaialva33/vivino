//// HTTP + WebSocket server for the relay.
////
//// Serves dashboard HTML and handles WebSocket connections.
//// Simplified version — no label_bridge or serial port (relay-only).

import gleam/bytes_tree
import gleam/erlang/process.{type Subject}
import gleam/http/request.{type Request}
import gleam/http/response.{type Response}
import gleam/int
import gleam/io
import gleam/option.{Some}
import mist.{
  type Connection, type ResponseData, type WebsocketConnection,
  type WebsocketMessage,
}
import vivino_relay/dashboard
import vivino_relay/pubsub

/// WebSocket custom message type
pub type WsMsg {
  DataMsg(String)
}

/// WebSocket state per client
pub type WsState {
  WsState(pubsub: Subject(pubsub.PubSubMsg), inbox: Subject(String))
}

/// Start the HTTP + WebSocket server
pub fn start(
  pubsub_subject: Subject(pubsub.PubSubMsg),
  port_num: Int,
) -> Result(Nil, String) {
  let handler = fn(req: Request(Connection)) -> Response(ResponseData) {
    route(req, pubsub_subject)
  }

  case
    handler
    |> mist.new
    |> mist.port(port_num)
    |> mist.start
  {
    Ok(_) -> {
      io.println(
        "VIVINO RELAY server at http://0.0.0.0:" <> int.to_string(port_num),
      )
      Ok(Nil)
    }
    Error(_) -> Error("Failed to start server")
  }
}

/// Route requests
fn route(
  req: Request(Connection),
  pubsub_subject: Subject(pubsub.PubSubMsg),
) -> Response(ResponseData) {
  case request.path_segments(req) {
    [] -> serve_dashboard()
    ["ws"] -> handle_websocket(req, pubsub_subject)
    _ ->
      response.new(404)
      |> response.set_body(mist.Bytes(bytes_tree.from_string("Not found")))
  }
}

/// Serve the dashboard HTML page with security headers
fn serve_dashboard() -> Response(ResponseData) {
  response.new(200)
  |> response.prepend_header("content-type", "text/html; charset=utf-8")
  |> response.prepend_header("x-frame-options", "DENY")
  |> response.prepend_header("x-content-type-options", "nosniff")
  |> response.prepend_header(
    "content-security-policy",
    "default-src 'self' 'unsafe-inline'; connect-src 'self' wss: ws:",
  )
  |> response.set_body(mist.Bytes(bytes_tree.from_string(dashboard.html())))
}

/// Handle WebSocket upgrade
fn handle_websocket(
  req: Request(Connection),
  pubsub_subject: Subject(pubsub.PubSubMsg),
) -> Response(ResponseData) {
  mist.websocket(
    request: req,
    on_init: fn(_conn: WebsocketConnection) {
      // Create inbox subject for this client
      let inbox = process.new_subject()

      // Subscribe to pubsub broadcasts
      process.send(pubsub_subject, pubsub.Subscribe(inbox))

      // Selector to receive broadcast messages as Custom(DataMsg)
      let selector =
        process.new_selector()
        |> process.select_map(inbox, fn(json) { DataMsg(json) })

      let state = WsState(pubsub: pubsub_subject, inbox:)
      #(state, Some(selector))
    },
    on_close: fn(state: WsState) {
      process.send(state.pubsub, pubsub.Unsubscribe(state.inbox))
    },
    handler: fn(
      state: WsState,
      msg: WebsocketMessage(WsMsg),
      conn: WebsocketConnection,
    ) {
      case msg {
        mist.Custom(DataMsg(json)) -> {
          case mist.send_text_frame(conn, json) {
            Ok(_) -> mist.continue(state)
            Error(_) -> mist.stop()
          }
        }
        mist.Text("ping") -> {
          case mist.send_text_frame(conn, "pong") {
            Ok(_) -> mist.continue(state)
            Error(_) -> mist.stop()
          }
        }
        mist.Text(_) -> {
          // Relay is READ-ONLY — drop all commands from remote browsers
          mist.continue(state)
        }
        mist.Closed | mist.Shutdown -> mist.stop()
        _ -> mist.continue(state)
      }
    },
  )
}
