-module(vivino_ffi).
-export([read_line/0, open_serial/2, detect_port/0, timestamp_ms/0,
         send_serial_cmd/1, read_port_line/1, write_serial/2]).

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
    DevStr = binary_to_list(Device),
    BaudStr = integer_to_list(Baud),
    %% Configure port: raw mode, no echo, immediate flush (min 1 time 0)
    SttyCmd = "stty -F " ++ DevStr ++ " " ++ BaudStr ++
        " raw -echo -echoe -echok -echoctl -echoke"
        " min 1 time 0 -hupcl 2>/dev/null",
    os:cmd(SttyCmd),
    timer:sleep(200),
    %% Flush any stale data from the port buffer
    os:cmd("cat " ++ DevStr ++ " > /dev/null &"),
    timer:sleep(50),
    os:cmd("kill %1 2>/dev/null"),
    %% Open as Erlang port with spawn_executable for safety (no shell injection)
    Port = open_port(
        {spawn_executable, "/usr/bin/cat"},
        [{args, [DevStr]}, binary, {line, 1024}, exit_status, use_stdio]
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
            {ok, Trimmed};
        {Port, {data, {noeol, Line}}} ->
            %% Partial line (longer than 1024 bytes), return as-is
            Trimmed = binary:replace(Line, <<"\r">>, <<>>),
            {ok, Trimmed};
        {Port, {exit_status, _Status}} ->
            {error, nil}
    after 10000 ->
        {error, nil}
    end.

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
    case filelib:is_file(Port) of
        true -> {ok, unicode:characters_to_binary(Port)};
        false -> detect_port(Rest)
    end.

%% Monotonic timestamp in milliseconds (for latency measurement)
timestamp_ms() ->
    erlang:monotonic_time(millisecond).

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
