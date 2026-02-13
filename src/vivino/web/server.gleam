//// HTTP + WebSocket server using mist.
////
//// Serves the real-time dashboard HTML and handles WebSocket connections
//// for streaming bioelectric data to browsers.

import gleam/bytes_tree
import gleam/erlang/process.{type Subject}
import gleam/http/request.{type Request}
import gleam/http/response.{type Response}
import gleam/int
import gleam/io
import gleam/option.{Some}
import gleam/string
import mist.{
  type Connection, type ResponseData, type WebsocketConnection,
  type WebsocketMessage,
}
import vivino/serial/port
import vivino/web/dashboard
import vivino/web/pubsub

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
        "VIVINO server at http://localhost:" <> int.to_string(port_num),
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

/// Serve the dashboard HTML page
fn serve_dashboard() -> Response(ResponseData) {
  response.new(200)
  |> response.prepend_header("content-type", "text/html; charset=utf-8")
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
        mist.Text(cmd) -> {
          let trimmed = string.trim(cmd)
          case trimmed {
            "H" | "F" | "E" | "S" | "X" -> {
              let _ = port.send_command(trimmed)
              io.println("CMD -> Arduino: " <> trimmed)
              let _ =
                mist.send_text_frame(
                  conn,
                  "{\"type\":\"cmd_ack\",\"cmd\":\"" <> trimmed <> "\"}",
                )
              mist.continue(state)
            }
            _ -> mist.continue(state)
          }
        }
        mist.Closed | mist.Shutdown -> mist.stop()
        _ -> mist.continue(state)
      }
    },
  )
}
