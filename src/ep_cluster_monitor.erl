%%%-------------------------------------------------------------------
%%% @author Maxim Fedorov <maximfca@gmail.com>
%%% @copyright (C) 2019, Maxim Fedorov
%%% @doc
%%%  Logs monitoring events for the entire cluster, to file or device.
%%%  Requires cluster_history service running, fails otherwise.
%%% @end
-module(ep_cluster_monitor).
-author("maximfca@gmail.com").

-behaviour(gen_server).

%% API
-export([
    start/0,
    start/2,
    start_link/2,
    stop/1
]).

%% gen_server callbacks
-export([
    init/1,
    handle_call/3,
    handle_cast/2,
    handle_info/2
]).

-include("monitor.hrl").

%% Handler: just like gen_event handler.
%% If you do need gen_event handler, make a fun of it.
-type handler() :: {module(), atom(), term()} | file:filename_all() | io:device().

%%--------------------------------------------------------------------
%% @doc
%% Starts additional cluster monitor, printing
%%  selected fields (sched_util, running job characteristics) to group_leader().
%% User is responsible for stopping the server.
-spec start() -> {ok, Pid :: pid()} | {error, Reason :: term()}.
start() ->
    start(erlang:group_leader(), [sched_util, jobs]).

%% @doc
%% Starts additional cluster-wide monitor.
%% User is responsible for stopping the server.
-spec start(handler(), [atom()]) -> {ok, Pid :: pid()} | {error, Reason :: term()}.
start(Handler, Fields) ->
    supervisor:start_child(ep_cluster_monitor_sup, [Handler, Fields]).

%% @doc
%% Starts cluster-wide monitor with the specified handler, and links it to the caller.
%% Use 'record_info(fields, monitor_sample)' to fetch all fields.
-spec start_link(handler(), [atom()]) -> {ok, Pid :: pid()} | {error, Reason :: term()}.
start_link(Handler, Fields) ->
    gen_server:start_link(?MODULE, [Handler, Fields], []).

%% @doc
%% Stops the cluster-wide monitor instance.
-spec stop(pid()) -> ok.
stop(Pid) ->
    supervisor:terminate_child(ep_cluster_monitor_sup, Pid).

%%%===================================================================
%%% gen_server callbacks

%% Take a sample every second
-define(SAMPLING_RATE, 1000).

%% System monitor state
-record(state, {
    % next tick
    next :: integer(),
    handler :: handler(),
    fields :: [integer()]
}).

%% gen_server init
init([Handler, Fields]) ->
    % precise (abs) timer
    Next = erlang:monotonic_time(millisecond) + ?SAMPLING_RATE,
    erlang:start_timer(Next, self(), tick, [{abs, true}]),
    {ok, #state{next = Next,
        handler = make_handler(Handler),
        fields = fields_to_indices(Fields)}}.

handle_call(_Request, _From, _State) ->
    error(badarg).

handle_cast(_Request, _State) ->
    error(badarg).

handle_info({timeout, _, tick}, #state{next = Next, fields = Fields, handler = Handler} = State) ->
    Next1 = Next + ?SAMPLING_RATE,
    % if we supply negative timer, we crash - and restart with no messages in the queue
    % this could happen if handler is too slow
    erlang:start_timer(Next1, self(), tick, [{abs, true}]),
    % fetch all updates from cluster history
    Samples = ep_cluster_history:get(Next - ?SAMPLING_RATE + erlang:time_offset(millisecond)),
    % now invoke the handler
    NewHandler = run_handler(Handler, Fields, lists:keysort(1, Samples)),
    {noreply, State#state{next = Next1, handler = NewHandler}};

handle_info(_Info, _State) ->
    error(badarg).

%%%===================================================================
%%% Internal functions

make_handler({_M, _F, _A} = MFA) ->
    MFA;
make_handler(IoDevice) when is_pid(IoDevice); is_atom(IoDevice) ->
    {fd, IoDevice};
make_handler(Filename) when is_list(Filename); is_binary(Filename) ->
    {ok, Fd} = file:open(Filename, [raw, append]),
    {fd, Fd}.

fields_to_indices(Names) ->
    Fields = record_info(fields, monitor_sample),
    Zips = lists:zip(Fields, lists:seq(1, length(Fields))),
    lists:reverse(lists:foldl(
        fun (Field, Inds) ->
            {Field, Ind} = lists:keyfind(Field, 1, Zips),
            [Ind | Inds]
        end, [], Names)).

run_handler({M, F, A}, Fields, Samples) ->
    Filtered = [{Node, [element(I + 1, Sample) || I <- Fields]} || {Node, Sample} <- Samples],
    {M, F, M:F(Filtered, A)};
run_handler({fd, IoDevice}, Fields, Samples) ->
    Filtered = lists:foldl(
        fun ({Node, Sample}, Acc) ->
            OneNode =
                lists:join(" ",
                    [io_lib:format("~s", [Node]) |
                        [formatter(I + 1, element(I + 1, Sample)) || I <- Fields]]),
            [OneNode | Acc]
        end,
        [], Samples),
    Data = lists:join(" ", Filtered) ++ "\n",
    Formatted = iolist_to_binary(Data),
    ok = file:write(IoDevice, Formatted),
    {fd, IoDevice}.

formatter(#monitor_sample.time, Time) ->
    calendar:system_time_to_rfc3339(Time div 1000);
formatter(Percent, Num) when Percent =:= #monitor_sample.sched_util; Percent =:= #monitor_sample.dcpu; Percent =:= #monitor_sample.dio ->
    io_lib:format("~6.2f", [Num]);
formatter(Number, Num) when Number =:= #monitor_sample.processes; Number =:= #monitor_sample.ports ->
    io_lib:format("~8b", [Num]);
formatter(#monitor_sample.ets, Num) ->
    io_lib:format("~6b", [Num]);
formatter(Size, Num) when Size =:= #monitor_sample.memory_total; Size =:= #monitor_sample.memory_processes; Size =:= #monitor_sample.memory_binary; Size =:= #monitor_sample.memory_ets ->
    io_lib:format("~9s", [erlperf:format_size(Num)]);
formatter(#monitor_sample.jobs, Jobs) ->
    lists:flatten([io_lib:format("~8s", [erlperf:format_number(Num)]) || {_Pid, Num} <- Jobs]).
