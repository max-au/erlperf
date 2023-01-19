%%% @copyright (C) 2019-2023, Maxim Fedorov
%%% @doc
%%% Prints monitoring reports produced by {@link erlperf_monitor} to file
%%% or an output device.
%%%
%%% When the server starts up, it joins `{erlperf, Node}' process group
%%% in the `erlperf' scope. If {@link erlperf_monitor} is also running in
%%% the same node, reports are printed to the specified device or file.
%%%
%%% See {@link erlperf_monitor} for description of the monitoring report.
%%%
%%% `erlperf' leverages this service for verbose output during benchmarking.
%%% @end
-module(erlperf_file_log).
-author("maximfca@gmail.com").

-behaviour(gen_server).

%% API
-export([
    start_link/0,
    start_link/1,
    %% leaky API...
    format_number/1,
    format_size/1,
    format_duration/1
]).

%% gen_server callbacks
-export([
    init/1,
    handle_call/3,
    handle_cast/2,
    handle_info/2
]).

%% @equiv start_link(erlang:group_leader())
-spec start_link() -> {ok, Pid :: pid()} | {error, Reason :: term()}.
start_link() ->
    start_link(erlang:group_leader()).

%% @doc
%% Starts the file log process.
-spec start_link(Filename :: string() | file:io_device()) -> {ok, Pid :: pid()} | {error, Reason :: term()}.
start_link(Filename) ->
    gen_server:start_link(?MODULE, [Filename], []).

%%%===================================================================
%%% gen_server callbacks

%% Repeat header every 30 lines (by default)
-define(LOG_REPEAT_HEADER, 30).

%% System monitor state
-record(state, {
    % file logger counter
    log_counter = ?LOG_REPEAT_HEADER :: non_neg_integer(),
    % when to print the header once again
    log_limit = ?LOG_REPEAT_HEADER :: pos_integer(),
    % file descriptor
    log_file :: file:io_device(),
    % current format line
    format = "" :: string(),
    % saved list of job IDs executed previously
    jobs = [] :: [erlperf_monitor:job_sample()]
}).

%% @private
init([Target]) ->
    % subscribe to monitor events
    ok = pg:join(erlperf, {erlperf_monitor, node()}, self()),
    WriteTo = if is_list(Target) -> {ok, LogFile} = file:open(Target, [raw, append]), LogFile; true -> Target end,
    {ok, #state{log_file = WriteTo}}.

%% @private
handle_call(_Request, _From, _State) ->
    erlang:error(notsup).

%% @private
handle_cast(_Request, _State) ->
    erlang:error(notsup).

%% @private
handle_info(#{jobs := Jobs, time := Time, sched_util := SchedUtil, dcpu := DCPU, dio := DIO, processes := Processes,
    ports := Ports, ets := Ets, memory_total := MemoryTotal, memory_processes := MemoryProcesses,
    memory_binary := MemoryBinary, memory_ets := MemoryEts}, #state{log_file = File} = State) ->
    {JobIds, Ts} = lists:unzip(Jobs),
    State1 = maybe_write_header(JobIds, State),
    % actual line
    TimeFormat = calendar:system_time_to_rfc3339(Time div 1000),
    Formatted = iolist_to_binary(io_lib:format(State1#state.format, [
        TimeFormat, SchedUtil, DCPU, DIO, Processes,
        Ports, Ets,
        format_size(MemoryTotal),
        format_size(MemoryProcesses),
        format_size(MemoryBinary),
        format_size(MemoryEts)
    ] ++ [format_number(T) || T <- Ts])),
    ok = file:write(File, Formatted),
    {noreply, State1}.

%%%===================================================================
%%% Internal functions

maybe_write_header(Jobs, #state{log_counter = LC, log_limit = LL, jobs = Prev} = State) when LC >= LL; Jobs =/= Prev ->
    State#state{format = write_header(State#state.log_file, Jobs), log_counter = 0, jobs = Jobs};
maybe_write_header(_, State) ->
    State#state{log_counter = State#state.log_counter + 1}.

write_header(File, Jobs) ->
    JobCount = length(Jobs),
    Format = "~s ~6.2f ~6.2f ~6.2f ~8b ~8b ~7b ~9s ~9s ~9s ~9s" ++
        lists:concat(lists:duplicate(JobCount, "~11s")) ++ "~n",
    JobIds = list_to_binary(lists:flatten([io_lib:format(" ~10s", [pid_to_list(J)]) || J <- Jobs])),
    Header =  <<"\nYYYY-MM-DDTHH:MM:SS-oo:oo  Sched   DCPU    DIO    Procs    Ports     ETS Mem Total  Mem Proc   Mem Bin   Mem ETS", JobIds/binary, "\n">>,
    ok = file:write(File, Header),
    Format.

%% @private
%% @doc Formats size (bytes) rounded to 3 digits.
%%  Unlike @see format_number, used 1024 as a base,
%%  so 200 * 1024 is 200 Kb.
-spec format_size(non_neg_integer()) -> string().
format_size(Num) when Num > 1024*1024*1024 * 100 ->
    integer_to_list(round(Num / (1024*1024*1024))) ++ " Gb";
format_size(Num) when Num > 1024*1024*100 ->
    integer_to_list(round(Num / (1024 * 1024))) ++ " Mb";
format_size(Num) when Num > 1024 * 100 ->
    integer_to_list(round(Num / 1024)) ++ " Kb";
format_size(Num) ->
    integer_to_list(Num).

%% @private
%% @doc Formats number rounded to 3 digits.
%%  Example: 88 -> 88, 880000 -> 880 Ki, 100501 -> 101 Ki
-spec format_number(non_neg_integer()) -> string().
format_number(Num) when Num > 100000000000 ->
    integer_to_list(round(Num / 1000000000)) ++ " Gi";
format_number(Num) when Num > 100000000 ->
    integer_to_list(round(Num / 1000000)) ++ " Mi";
format_number(Num) when Num > 100000 ->
    integer_to_list(round(Num / 1000)) ++ " Ki";
format_number(Num) ->
    integer_to_list(Num).

%% @private
%% @doc Formats time duration, from nanoseconds to seconds
%%  Example: 88 -> 88 ns, 88000 -> 88 us, 10000000 -> 10 ms
-spec format_duration(non_neg_integer() | infinity) -> string().
format_duration(infinity) ->
    "inf";
format_duration(Num) when Num > 100000000000 ->
    integer_to_list(round(Num / 1000000000)) ++ " s";
format_duration(Num) when Num > 100000000 ->
    integer_to_list(round(Num / 1000000)) ++ " ms";
format_duration(Num) when Num > 100000 ->
    integer_to_list(round(Num / 1000)) ++ " us";
format_duration(Num) ->
    integer_to_list(Num) ++ " ns".