-module(vivino_relay_ffi).
-export([tcp_listen/1, tcp_accept/1, tcp_recv_line/1, tcp_close/1, get_env/1,
         tcp_recv_auth/2]).

%% Listen on a TCP port for incoming connections from Vivino local.
tcp_listen(Port) ->
    case gen_tcp:listen(Port, [binary, {packet, line}, {active, false},
                               {reuseaddr, true}, {nodelay, true},
                               {recbuf, 65536}, {sndbuf, 65536}]) of
        {ok, Socket} -> {ok, Socket};
        {error, _Reason} -> {error, nil}
    end.

%% Accept a connection on the listening socket.
%% Blocks up to 30s waiting for a client.
tcp_accept(ListenSocket) ->
    case gen_tcp:accept(ListenSocket, 30000) of
        {ok, Socket} -> {ok, Socket};
        {error, _Reason} -> {error, nil}
    end.

%% Receive a line from the connected client.
%% {packet, line} ensures we get complete JSON lines.
%% Skip binary:replace — JSON.parse handles trailing whitespace.
tcp_recv_line(Socket) ->
    case gen_tcp:recv(Socket, 0, 10000) of
        {ok, Data} -> {ok, Data};
        {error, _Reason} -> {error, nil}
    end.

%% Authenticate TCP client: expects "AUTH:<secret>\n" as first line.
%% Returns {ok, nil} if auth matches, {error, nil} otherwise.
tcp_recv_auth(Socket, ExpectedSecret) ->
    case gen_tcp:recv(Socket, 0, 5000) of
        {ok, Data} ->
            Trimmed = binary:replace(Data, <<"\n">>, <<>>),
            case Trimmed of
                <<"AUTH:", Token/binary>> ->
                    case Token =:= ExpectedSecret of
                        true -> {ok, nil};
                        false -> {error, nil}
                    end;
                _ -> {error, nil}
            end;
        {error, _} -> {error, nil}
    end.

%% Close a TCP socket.
tcp_close(Socket) ->
    gen_tcp:close(Socket),
    {ok, nil}.

%% Read environment variable.
get_env(Name) ->
    case os:getenv(binary_to_list(Name)) of
        false -> {error, nil};
        Value -> {ok, unicode:characters_to_binary(Value)}
    end.
