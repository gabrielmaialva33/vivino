//// Vivino Relay — receives bioelectric data via TCP from local Vivino
//// and serves the dashboard to remote browsers via HTTP + WebSocket.
////
//// Architecture: Vivino local → TCP:5000 → this relay → WS → browsers
//// Cloudflare Tunnel handles HTTPS/WSS termination.

import gleam/dynamic.{type Dynamic}
import gleam/erlang/process
import gleam/int
import gleam/io
import gleam/result
import vivino_relay/pubsub
import vivino_relay/server

@external(erlang, "vivino_relay_ffi", "get_env")
fn get_env(name: String) -> Result(String, Nil)

@external(erlang, "vivino_relay_ffi", "tcp_listen")
fn tcp_listen(port: Int) -> Result(Dynamic, Nil)

@external(erlang, "vivino_relay_ffi", "tcp_accept")
fn tcp_accept(listen_socket: Dynamic) -> Result(Dynamic, Nil)

@external(erlang, "vivino_relay_ffi", "tcp_recv_line")
fn tcp_recv_line(socket: Dynamic) -> Result(String, Nil)

@external(erlang, "vivino_relay_ffi", "tcp_close")
fn tcp_close(socket: Dynamic) -> Result(Nil, Nil)

@external(erlang, "vivino_relay_ffi", "tcp_recv_auth")
fn tcp_recv_auth(socket: Dynamic, secret: String) -> Result(Nil, Nil)

pub fn main() {
  // Configurable ports via env vars (defaults: HTTP=3000, TCP=5000)
  let http_port =
    get_env("RELAY_HTTP_PORT")
    |> result.try(int.parse)
    |> result.unwrap(3000)
  let tcp_port =
    get_env("RELAY_TCP_PORT")
    |> result.try(int.parse)
    |> result.unwrap(5000)

  // Shared secret for TCP auth (optional — if unset, no auth)
  let relay_secret = get_env("RELAY_SECRET") |> result.unwrap("")

  // Start PubSub actor
  let assert Ok(pubsub_subject) = pubsub.start()

  // Start HTTP + WebSocket server
  let assert Ok(_) = server.start(pubsub_subject, http_port)
  io.println("Dashboard at http://0.0.0.0:" <> int.to_string(http_port))

  // Start TCP relay listener
  let assert Ok(listen) = tcp_listen(tcp_port)
  io.println("TCP relay listening on :" <> int.to_string(tcp_port))
  case relay_secret {
    "" -> io.println("WARNING: No RELAY_SECRET set — TCP auth disabled!")
    _ -> io.println("TCP auth enabled (RELAY_SECRET)")
  }

  // Accept loop — waits for Vivino local to connect
  accept_loop(listen, pubsub_subject, relay_secret)
}

/// Wait for a Vivino client to connect, authenticate, then receive data.
fn accept_loop(
  listen: Dynamic,
  pubsub_subject: pubsub.PubSubSubject,
  secret: String,
) {
  case tcp_accept(listen) {
    Ok(client) -> {
      case secret {
        "" -> {
          // No auth configured — accept directly
          io.println("Vivino connected (no auth)")
          recv_loop(client, pubsub_subject, listen, secret)
        }
        _ ->
          case tcp_recv_auth(client, secret) {
            Ok(_) -> {
              io.println("Vivino connected (authenticated)")
              recv_loop(client, pubsub_subject, listen, secret)
            }
            Error(_) -> {
              io.println("TCP auth FAILED — dropping connection")
              let _ = tcp_close(client)
              accept_loop(listen, pubsub_subject, secret)
            }
          }
      }
    }
    Error(_) -> {
      // Timeout or error — just retry
      accept_loop(listen, pubsub_subject, secret)
    }
  }
}

/// Receive JSON lines from Vivino and broadcast to WebSocket clients.
fn recv_loop(
  client: Dynamic,
  pubsub_subject: pubsub.PubSubSubject,
  listen: Dynamic,
  secret: String,
) {
  case tcp_recv_line(client) {
    Ok(json) -> {
      // Broadcast to all connected WebSocket clients
      process.send(pubsub_subject, pubsub.Broadcast(json))
      recv_loop(client, pubsub_subject, listen, secret)
    }
    Error(_) -> {
      // Client disconnected — close and wait for reconnection
      io.println("Vivino disconnected, waiting for reconnection...")
      let _ = tcp_close(client)
      accept_loop(listen, pubsub_subject, secret)
    }
  }
}
