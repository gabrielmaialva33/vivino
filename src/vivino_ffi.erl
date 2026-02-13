-module(vivino_ffi).
-export([read_line/0, open_serial/2, detect_port/0, timestamp_ms/0,
         send_serial_cmd/1, read_port_line/1, write_serial/2,
         put_label/1, get_label/0, put_organism/1, get_organism/0,
         get_env/1]).

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
