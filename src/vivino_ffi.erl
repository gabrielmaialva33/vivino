-module(vivino_ffi).
-export([read_line/0, open_serial/2, detect_port/0, timestamp_ms/0,
         send_serial_cmd/1, read_port_line/1, write_serial/2,
         put_label/1, get_label/0, put_organism/1, get_organism/0,
         get_env/1,
         tcp_connect/2, tcp_send/2, tcp_close/1,
         ptz_move/2, ptz_stop/1,
         open_vision/3, read_vision_line/1, vision_cmd/2,
         speak/1]).

%% Read a line from stdin with error handling.
%% Returns {ok, Binary} | {error, nil}
read_line() ->
    case catch read_line_unsafe() of
        {ok, Bin} -> {ok, Bin};
        _ -> {error, nil}
    end.

read_line_unsafe() ->
    case io:get_line("") of
        eof -> {error, nil};
        {error, _} -> {error, nil};
        Line ->
            %% Normalize to binary, trim trailing newlines
            Bin = unicode:characters_to_binary(Line),
            Trimmed = binary:replace(Bin, <<"\n">>, <<>>),
            Trimmed2 = binary:replace(Trimmed, <<"\r">>, <<>>),
            {ok, Trimmed2}
    end.

%% Open serial port via Erlang port (low-latency).
%% Uses stty for configuration + spawn_executable for safety.
open_serial(Device, Baud) ->
    BaudStr = integer_to_list(Baud),
    %% Use Python serial reader — handles DTR properly for CH340/Arduino
    %% Python sets DTR=False to prevent Arduino reset, filters ASCII, flushes garbage
    PrivDir = code:priv_dir(vivino),
    ReaderPath = filename:join(PrivDir, "serial_reader.py"),
    Port = open_port(
        {spawn_executable, "/usr/bin/python3"},
        [{args, [ReaderPath, binary_to_list(Device), BaudStr]},
         binary, {line, 1024}, exit_status, use_stdio]
    ),
    %% Store device path for write_serial
    persistent_term:put(vivino_serial_device, Device),
    {ok, Port}.

%% Read a line from an Erlang port (serial device opened via open_serial).
%% Receives {Port, {data, {eol, Line}}} messages from the port.
%% Timeout after 10s to avoid hanging forever.
read_port_line(Port) ->
    receive
        {Port, {data, {eol, Line}}} ->
            %% Trim CR if present
            Trimmed = binary:replace(Line, <<"\r">>, <<>>),
            %% Skip non-ASCII/binary garbage (bootloader noise)
            case is_printable_ascii(Trimmed) of
                true -> {ok, Trimmed};
                false -> read_port_line(Port)
            end;
        {Port, {data, {noeol, Line}}} ->
            Trimmed = binary:replace(Line, <<"\r">>, <<>>),
            case is_printable_ascii(Trimmed) of
                true -> {ok, Trimmed};
                false -> read_port_line(Port)
            end;
        {Port, {exit_status, _Status}} ->
            {error, nil}
    after 10000 ->
        {error, nil}
    end.

%% Check if binary contains only printable ASCII (0x20-0x7E) + common chars
is_printable_ascii(<<>>) -> true;
is_printable_ascii(<<C, Rest/binary>>) when C >= 32, C =< 126 ->
    is_printable_ascii(Rest);
is_printable_ascii(<<$\t, Rest/binary>>) ->
    is_printable_ascii(Rest);
is_printable_ascii(_) -> false.

%% Write data directly to serial device (for sending commands to Arduino).
%% Opens device file for writing, sends data + newline, closes.
write_serial(Device, Data) ->
    DevStr = binary_to_list(Device),
    case file:open(DevStr, [write, raw]) of
        {ok, Fd} ->
            Res = file:write(Fd, [Data, "\n"]),
            file:close(Fd),
            case Res of
                ok -> {ok, nil};
                _ -> {error, nil}
            end;
        {error, _} ->
            {error, nil}
    end.

%% Auto-detect Arduino serial port (CH340 or ACM)
detect_port() ->
    Ports = ["/dev/ttyUSB0", "/dev/ttyUSB1", "/dev/ttyUSB2",
             "/dev/ttyACM0", "/dev/ttyACM1"],
    detect_port(Ports).

detect_port([]) ->
    {error, nil};
detect_port([Port | Rest]) ->
    case file:read_file_info(Port) of
        {ok, _} -> {ok, unicode:characters_to_binary(Port)};
        _ -> detect_port(Rest)
    end.

%% Monotonic timestamp in milliseconds (for latency measurement)
timestamp_ms() ->
    erlang:monotonic_time(millisecond).

%% Label management via persistent_term (WebSocket -> main loop)
put_label(Label) ->
    persistent_term:put(vivino_pending_label, Label),
    {ok, nil}.

get_label() ->
    case catch persistent_term:get(vivino_pending_label) of
        {'EXIT', _} -> {error, nil};
        undefined -> {error, nil};
        Label ->
            persistent_term:put(vivino_pending_label, undefined),
            {ok, Label}
    end.

%% Organism selection via persistent_term
put_organism(Organism) ->
    persistent_term:put(vivino_organism, Organism),
    {ok, nil}.

get_organism() ->
    case catch persistent_term:get(vivino_organism) of
        {'EXIT', _} -> {ok, <<"shimeji">>};
        undefined -> {ok, <<"shimeji">>};
        Org -> {ok, Org}
    end.

%% Read environment variable. Returns {ok, Value} | {error, nil}
get_env(Name) ->
    case os:getenv(binary_to_list(Name)) of
        false -> {error, nil};
        Value -> {ok, unicode:characters_to_binary(Value)}
    end.

%% Send a command to Arduino via serial device.
%% Uses persistent_term to get device path stored during open_serial.
send_serial_cmd(Cmd) ->
    case catch persistent_term:get(vivino_serial_device) of
        Device when is_binary(Device) ->
            write_serial(Device, Cmd);
        _ ->
            %% Fallback: try FIFO for backwards compat
            Fifo = "/tmp/vivino_cmd",
            case catch file:write_file(Fifo, Cmd) of
                ok -> {ok, nil};
                _ -> {error, nil}
            end
    end.

%% ============================================================
%% PTZ camera control via RTSP SET_PARAMETER
%% ============================================================

%% Move camera via RTSP SET_PARAMETER command.
%% Direction: <<"UP">>, <<"DWON">>, <<"LEFT">>, <<"RIGHT">>, <<"STOP">>
%% Note: Yoosee firmware uses "DWON" (typo), not "DOWN".
ptz_move(Ip, Direction) ->
    case gen_tcp:connect(binary_to_list(Ip), 554,
                          [binary, {active, false}], 5000) of
        {ok, Sock} ->
            Setup = [<<"SETUP rtsp://">>, Ip, <<"/onvif1/track1 RTSP/1.0\r\n">>,
                     <<"CSeq: 1\r\nUser-Agent: Vivino/1.0\r\n">>,
                     <<"Transport: RTP/AVP/TCP;unicast;interleaved=0-1\r\n\r\n">>],
            gen_tcp:send(Sock, Setup),
            gen_tcp:recv(Sock, 0, 5000),
            Ptz = [<<"SET_PARAMETER rtsp://">>, Ip, <<"/onvif1 RTSP/1.0\r\n">>,
                   <<"Content-type: ptzCmd: ">>, Direction, <<"\r\n">>,
                   <<"CSeq: 2\r\nSession:\r\n\r\n">>],
            gen_tcp:send(Sock, Ptz),
            gen_tcp:recv(Sock, 0, 2000),
            gen_tcp:close(Sock),
            {ok, nil};
        {error, _Reason} ->
            {error, nil}
    end.

ptz_stop(Ip) ->
    ptz_move(Ip, <<"STOP">>).

%% ============================================================
%% Vision detector (Python sidecar via Erlang port)
%% ============================================================

%% Open vision detector Python sidecar.
%% Same pattern as open_serial — spawn_executable + line protocol.
open_vision(RtspUrl, ModelPath, Conf) ->
    PrivDir = code:priv_dir(vivino),
    DetectorPath = filename:join(PrivDir, "vision_detector.py"),
    ConfStr = float_to_list(Conf, [{decimals, 2}]),
    Python = case os:find_executable("python3") of
        false -> "/usr/bin/python3";
        Path -> Path
    end,
    Port = open_port(
        {spawn_executable, Python},
        [{args, ["-u", DetectorPath,
                 binary_to_list(RtspUrl),
                 "--model", binary_to_list(ModelPath),
                 "--conf", ConfStr]},
         binary, {line, 8192}, exit_status, use_stdio]
    ),
    {ok, Port}.

%% Read a JSON line from the vision port.
%% Longer timeout than serial (RTSP buffering + GPU warmup).
read_vision_line(Port) ->
    receive
        {Port, {data, {eol, Line}}} ->
            {ok, Line};
        {Port, {data, {noeol, Line}}} ->
            {ok, Line};
        {Port, {exit_status, _Status}} ->
            {error, nil}
    after 30000 ->
        {error, nil}
    end.

%% Send command to vision detector (change conf, classes, stop).
vision_cmd(Port, Cmd) ->
    port_command(Port, [Cmd, "\n"]),
    {ok, nil}.

%% ============================================================
%% Text-to-Speech via espeak-ng (fire-and-forget)
%% ============================================================

speak(Text) ->
    spawn(fun() ->
        try
            Port = open_port({spawn_executable, "/usr/bin/espeak-ng"},
                [{args, ["-v", "pt-br", "-s", "140",
                         binary_to_list(Text)]},
                 exit_status, use_stdio, binary, stderr_to_stdout]),
            receive
                {Port, {exit_status, _}} -> ok
            after 15000 ->
                catch port_close(Port)
            end
        catch _:_ -> ok
        end
    end),
    nil.

%% TCP relay client — connect to remote VPS relay server
tcp_connect(Host, Port) ->
    case gen_tcp:connect(binary_to_list(Host), Port,
                         [binary, {packet, line}, {active, false},
                          {nodelay, true}, {recbuf, 65536},
                          {sndbuf, 65536}], 5000) of
        {ok, Socket} -> {ok, Socket};
        {error, _Reason} -> {error, nil}
    end.

%% Send JSON line over TCP (appends newline for {packet, line})
tcp_send(Socket, Data) ->
    case gen_tcp:send(Socket, [Data, "\n"]) of
        ok -> {ok, nil};
        {error, _} -> {error, nil}
    end.

%% Close TCP socket
tcp_close(Socket) ->
    gen_tcp:close(Socket),
    {ok, nil}.
