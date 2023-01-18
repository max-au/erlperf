%%% @copyright (C) 2019-2023, Maxim Fedorov
%%% @doc
%%% Logs monitoring events for the entire cluster, to file or device.
%%%  Requires erlperf_history service running, fails otherwise.
%%% Uses completely different to erlperf_monitor approach; instead of waiting
%%%  for new samples to come, cluster monitor just outputs existing
%%%  samples periodically.
%%% @end
-module(erlperf_cluster_monitor).
-author("maximfca@gmail.com").

-behaviour(gen_server).

%% API
-export([
    start_link/2
]).

%% gen_server callbacks
-export([
    init/1,
    handle_call/3,
    handle_cast/2,
    handle_info/2
]).

%% Handler: just like gen_event handler.
%% If you do need gen_event handler, make a fun of it.
-type handler() :: {module(), atom(), term()} | file:filename_all() | {fd, io:device()} | io:device().

%% @doc
%% Starts cluster-wide monitor with the specified handler, and links it to the caller.
%% Use 'record_info(fields, monitor_sample)' to fetch all fields.
-spec start_link(handler(), [atom()]) -> {ok, Pid :: pid()} | {error, Reason :: term()}.
start_link(Handler, Fields) ->
    gen_server:start_link(?MODULE, [Handler, Fields], []).

%%%===================================================================
%%% gen_server callbacks

%% Take a sample every second
-define(SAMPLING_RATE, 1000).

%% System monitor state
-record(state, {
    %% next tick
    next :: integer(),
    handler :: handler(),
    fields :: [atom()],
    %% previously printed header, elements are node() | field name | job PID
    %% if the new header is different from the previous one, it gets printed
    header = [] :: [atom() | {jobs, [pid()]} | {node, node()}]
}).

%% gen_server init
init([Handler, Fields]) ->
    %% precise (abs) timer
    Next = erlang:monotonic_time(millisecond) + ?SAMPLING_RATE,
    {ok, handle_tick(#state{next = Next, handler = make_handler(Handler), fields = Fields})}.

handle_call(_Request, _From, _State) ->
    erlang:error(notsup).

handle_cast(_Request, _State) ->
    erlang:error(notsup).

handle_info({timeout, _, tick}, State) ->
    {noreply, handle_tick(State)}.

%%%===================================================================
%%% Internal functions

handle_tick(#state{next = Next, fields = Fields, handler = Handler, header = Header} = State) ->
    Next1 = Next + ?SAMPLING_RATE,
    %% if we supply negative timer, we crash - and restart with no messages in the queue
    %% this could happen if handler is too slow
    erlang:start_timer(Next1, self(), tick, [{abs, true}]),
    %% fetch all updates from cluster history
    Samples = erlperf_history:get(Next - ?SAMPLING_RATE + erlang:time_offset(millisecond)),
    %% now invoke the handler
    {NewHandler, NewHeader} = run_handler(Handler, Fields, Header, lists:keysort(1, Samples)),
    State#state{next = Next1, handler = NewHandler, header = NewHeader}.

make_handler({_M, _F, _A} = MFA) ->
    MFA;
make_handler(IoDevice) when is_pid(IoDevice); is_atom(IoDevice) ->
    {fd, IoDevice};
make_handler(Filename) when is_list(Filename); is_binary(Filename) ->
    {ok, Fd} = file:open(Filename, [raw, append]),
    {fd, Fd}.

run_handler(Handler, _Fields, Header, []) ->
    {Handler, Header};

%% handler: MFA callback
run_handler({M, F, A}, Fields, Header, Samples) ->
    Filtered = [{Node, maps:with(Fields, Sample)} || {Node, Sample} <- Samples],
    {{M, F, M:F(Filtered, A)}, Header};

%% built-in handler: file/console output
run_handler({fd, IoDevice}, Fields, Header, Samples) ->
    {NewHeader, Filtered} = lists:foldl(
        fun ({Node, Sample}, {Hdr, Acc}) ->
            OneNode =
                lists:join(" ",
                    [io_lib:format("~s", [Node]) |
                        [formatter(F, maps:get(F, Sample)) || F <- Fields]]),
            %% special case for Jobs: replace the field with the {jobs, [Job]}
            FieldsWithJobs = [
                case F of
                    jobs -> {Pids, _} = lists:unzip(maps:get(jobs, Sample)), {jobs, Pids};
                    F -> F
                end || F <- Fields],
            {[{node, Node} | FieldsWithJobs] ++ Hdr, [OneNode | Acc]}
        end,
        {[], []}, Samples),
    %% check if header has changed and print if it has
    NewHeader =/= Header andalso
        begin
            FmtHdr = iolist_to_binary(lists:join(" ", [header(S) || S <- NewHeader])),
            ok = file:write(IoDevice, FmtHdr)
        end,
    %% print the actual line
    Data = lists:join(" ", Filtered) ++ "\n",
    Formatted = iolist_to_binary(Data),
    ok = file:write(IoDevice, Formatted),
    {{fd, IoDevice}, NewHeader}.

header(time) -> "      date     time    TZ";
header(sched_util) -> "%sched";
header(dcpu) -> " %dcpu";
header(dio) -> "  %dio";
header(processes) -> "  procs";
header(ports) -> "  ports";
header(ets) -> "  ets";
header(memory_total) -> "mem_total";
header(memory_processes) -> " mem_proc";
header(memory_binary) -> "  mem_bin";
header(memory_ets) -> "  mem_ets";
header({jobs, Jobs}) ->
    lists:flatten([io_lib:format("~14s", [pid_to_list(Pid)]) || Pid <- Jobs]);
header({node, Node}) ->
    atom_to_list(Node).

formatter(time, Time) ->
    calendar:system_time_to_rfc3339(Time div 1000);
formatter(Percent, Num) when Percent =:= sched_util; Percent =:= dcpu; Percent =:= dio ->
    io_lib:format("~6.2f", [Num]);
formatter(Number, Num) when Number =:= processes; Number =:= ports ->
    io_lib:format("~7b", [Num]);
formatter(ets, Num) ->
    io_lib:format("~5b", [Num]);
formatter(Size, Num) when Size =:= memory_total; Size =:= memory_processes; Size =:= memory_binary; Size =:= memory_ets ->
    io_lib:format("~9s", [erlperf_file_log:format_size(Num)]);
formatter(jobs, Jobs) ->
    lists:flatten([io_lib:format("~14s", [erlperf_file_log:format_number(Num)]) || {_Pid, Num} <- Jobs]).
