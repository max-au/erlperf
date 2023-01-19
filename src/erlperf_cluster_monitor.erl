%%% @copyright (C) 2019-2023, Maxim Fedorov
%%% @doc
%%% Logs monitoring events for the entire cluster, to file or device.
%%%  Requires {@link erlperf_history} service running, fails otherwise.
%%% Uses completely different to {@link erlperf_monitor} approach; instead of waiting
%%%  for new samples to come, cluster monitor just outputs existing
%%%  samples periodically.
%%%
%%% Example primary node:
%%% ```
%%%     rebar3 shell --sname primary
%%%     (primary@ubuntu22)1> erlperf_history:start_link().
%%%     {ok,<0.211.0>}
%%%     (primary@ubuntu22)2> erlperf_cluster_monitor:start_link().
%%%     {ok,<0.216.0>}
%%% '''
%%%
%%% Example benchmarking node:
%%% ```
%%%     rebar3 shell --sname bench1
%%%     (bench1@ubuntu22)1> net_kernel:connect_node('primary@ubuntu22').
%%%     true
%%%     (bench1@ubuntu22)2> erlperf:run(rand, uniform, []).
%%% '''
%%%
%%% As soon as the new benchmarking jon on the node `bench' is started, it is
%%% reported in the cluster monitoring output.
%%% @end
-module(erlperf_cluster_monitor).
-author("maximfca@gmail.com").

-behaviour(gen_server).

%% API
-export([
    start_link/0,
    start_link/3
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
%% Specifies monitoring output device.
%%
%% It could be an output {@link io:device()} (such as
%% {@link erlang:group_leader/0}, `user' or `standard_error'), a file name, or a
%% `{Module, Function, UserState}' tuple. In the latter case, instead of printing, cluster monitor
%% calls the specified function, which must have arity of 2, accepting filtered
%% {@link erlperf_monitor:monitor_sample()} as the first argument, and `Userstate' as the second,
%% returning next `UserState'.


%% Take a sample every second
-define(DEFAULT_INTERVAL, 1000).

-define(KNOWN_FIELDS, [time, sched_util, dcpu, dio, processes, ports, ets, memory_total,
    memory_processes, memory_ets, jobs]).

%% @equiv start_link(erlang:group_leader(), 1000, undefined)
-spec start_link() -> {ok, Pid :: pid()} | {error, Reason :: term()}.
start_link() ->
    start_link(erlang:group_leader(), ?DEFAULT_INTERVAL, undefined).

%% @doc
%% Starts cluster-wide monitor process, and links it to the caller.
%%
%% Intended to be used in a supervisor `ChildSpec', making the process a part of the supervision tree.
%%
%% `IntervalMs' specifies time, in milliseconds, between output handler invocations.
%%
%% Fields specifies the list of field names to report, and the order in which columns are printed.
%% see {@link erlperf_monitor:monitor_sample()} for options. Passing `undefined' prints all columns
%% known by this version of `erlperf'.
%% @end
-spec start_link(Handler :: handler(), IntervalMs :: pos_integer(), Fields :: [atom()] | undefined) ->
    {ok, Pid :: pid()} | {error, Reason :: term()}.
start_link(Handler, Interval, Fields) ->
    gen_server:start_link(?MODULE, [Handler, Interval, Fields], []).

%%%===================================================================
%%% gen_server callbacks

%% System monitor state
-record(state, {
    %% next tick
    next :: integer(),
    interval :: pos_integer(),
    handler :: handler(),
    fields :: [atom()] | undefined,
    %% previously printed header, elements are node() | field name | job PID
    %% if the new header is different from the previous one, it gets printed
    header = [] :: [atom() | {jobs, [pid()]} | {node, node()}]
}).

%% @private
init([Handler, Interval, Fields0]) ->
    %% precise (abs) timer
    Fields = if Fields0 =:= undefined -> ?KNOWN_FIELDS; true -> Fields0 end,
    Next = erlang:monotonic_time(millisecond) + Interval,
    {ok, handle_tick(#state{next = Next, interval = Interval, handler = make_handler(Handler), fields = Fields})}.

%% @private
handle_call(_Request, _From, _State) ->
    erlang:error(notsup).

%% @private
handle_cast(_Request, _State) ->
    erlang:error(notsup).

%% @private
handle_info({timeout, _, tick}, State) ->
    {noreply, handle_tick(State)}.

%%%===================================================================
%%% Internal functions

handle_tick(#state{next = Next, interval = Interval, fields = Fields, handler = Handler, header = Header} = State) ->
    Next1 = Next + Interval,
    %% if we supply negative timer, we crash - and restart with no messages in the queue
    %% this could happen if handler is too slow
    erlang:start_timer(Next1, self(), tick, [{abs, true}]),
    %% fetch all updates from cluster history
    Samples = erlperf_history:get(Next - Interval + erlang:time_offset(millisecond)),
    %% now invoke the handler
    {NewHandler, NewHeader} = run_handler(Handler, Fields, Header, lists:keysort(1, Samples)),
    State#state{next = Next1, handler = NewHandler, header = NewHeader}.

make_handler({_M, _F, _A} = MFA) ->
    MFA;
make_handler(IoDevice) when is_pid(IoDevice); is_atom(IoDevice) ->
    {fd, IoDevice};
make_handler({fd, IoDevice}) when is_pid(IoDevice); is_atom(IoDevice) ->
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
            ok = file:write(IoDevice, <<FmtHdr/binary, "\n">>)
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
