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

-define(KNOWN_FIELDS, [time, node, sched_util, dcpu, dio, processes, ports, ets, memory_total,
    memory_processes, memory_binary, memory_ets, jobs]).

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
    next :: integer(), %% absolute timer for the next tick
    interval :: pos_integer(),
    handler :: handler(),
    fields :: [atom()] | undefined,
    %% previously printed header
    %% if the new header is different from the previous one, it gets printed
    header = [] :: [atom() | [pid()]]
}).

%% @private
init([Handler, Interval, Fields0]) ->
    Fields = if Fields0 =:= undefined -> ?KNOWN_FIELDS; true -> Fields0 end,
    %% use absolute timer to avoid skipping ticks
    Now = erlang:monotonic_time(millisecond),
    {ok, handle_tick(#state{next = Now, interval = Interval, handler = make_handler(Handler), fields = Fields})}.

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

handle_tick(#state{next = Now, interval = Interval, fields = Fields, handler = Handler, header = Header} = State) ->
    Next = Now + Interval,
    %%
    erlang:start_timer(Next, self(), tick, [{abs, true}]),
    %% last interval updates
    GetHistoryTo = Now + erlang:time_offset(millisecond),
    %% be careful not to overlap the timings (history:get is inclusive)
    Samples = erlperf_history:get(GetHistoryTo - Interval + 1, GetHistoryTo),
    %% now invoke the handler
    {NewHandler, NewHeader} = run_handler(Handler, Fields, Header, Samples),
    State#state{next = Next, handler = NewHandler, header = NewHeader}.

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
    Filtered = [{Time, maps:with(Fields, Sample)} || {Time, Sample} <- Samples],
    {{M, F, M:F(Filtered, A)}, Header};

%% built-in handler: file/console output
run_handler({fd, IoDevice}, Fields, Header, Samples) ->
    %% the idea of the formatter below is to print lines like this:
    %% Dane       Time     node         sched ets  memory   <123.456.1> <0.123.0>
    %% 2022-11-12 08:35:16 node1@host   33.5%  16  128111         12345
    %% 2022-11-12 08:35:16 node1@host   33.5%  16  128111                    9111

    %% collect all jobs from all samples
    Jobs = lists:usort(lists:foldl(
        fun ({_Time, #{jobs := Jobs}}, Acc) -> {Pids, _} = lists:unzip(Jobs), Pids ++ Acc end,
        [], Samples)),

    %% replace atom 'jobs' with list of Jobs. This is effectively lists:keyreplace, but with no key
    NewHeader = [if F =:= jobs -> Jobs; true -> F end || F <- Fields],

    %% format specific fields of samples
    Formatted = [
        [formatter(F, if is_list(F) -> maps:get(jobs, Sample); true -> maps:get(F, Sample) end) || F <- NewHeader]
        || {_Time, Sample} <- Samples],

    NewLine = io_lib:nl(),
    BinNl = list_to_binary(NewLine),

    %% check if header has changed and print if it has
    NewHeader =/= Header andalso
        begin
            FmtHdr = [header(S) || S <- NewHeader] ++ [BinNl],
            ok = file:write(IoDevice, FmtHdr)
        end,

    %% print the actual line
    Data = [F ++ NewLine || F <- Formatted],
    ok = file:write(IoDevice, Data),
    {{fd, IoDevice}, NewHeader}.

header(time) -> <<"      date     time    TZ ">>;
header(sched_util) -> <<" %sched">>;
header(dcpu) -> <<"  %dcpu">>;
header(dio) -> <<"   %dio">>;
header(processes) -> <<"   procs">>;
header(ports) -> <<"   ports">>;
header(ets) -> <<"   ets">>;
header(memory_total) -> <<" mem_total">>;
header(memory_processes) -> <<"  mem_proc">>;
header(memory_binary) -> <<"   mem_bin">>;
header(memory_ets) -> <<"   mem_ets">>;
header(Jobs) when is_list(Jobs) ->
    iolist_to_binary([io_lib:format("~16s", [pid_to_list(Pid)]) || Pid <- Jobs]);
header(node) -> <<"node                  ">>.

formatter(time, Time) ->
    calendar:system_time_to_rfc3339(Time div 1000) ++ " ";
formatter(Percent, Num) when Percent =:= sched_util; Percent =:= dcpu; Percent =:= dio ->
    io_lib:format("~7.2f", [Num]);
formatter(Number, Num) when Number =:= processes; Number =:= ports ->
    io_lib:format("~8b", [Num]);
formatter(ets, Num) ->
    io_lib:format("~6b", [Num]);
formatter(Size, Num) when Size =:= memory_total; Size =:= memory_processes; Size =:= memory_binary; Size =:= memory_ets ->
    io_lib:format("~10s", [erlperf_file_log:format_size(Num)]);
formatter(Jobs, JobsInSample) when is_list(Jobs) ->
    %% here, all Jobs must be formatter, potentially empty (if they are not in JobsInSample)
    [case lists:keyfind(Job, 1, JobsInSample) of
         {Job, Num} -> io_lib:format("~16s", [erlperf_file_log:format_number(Num)]);
         false -> "                " end
        || Job <- Jobs];
formatter(node, Node) ->
    io_lib:format("~*s", [-22, Node]).
