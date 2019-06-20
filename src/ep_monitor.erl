%%%-------------------------------------------------------------------
%%% @author Maxim Fedorov <maximfca@gmail.com>
%%% @copyright (C) 2019, Maxim Fedorov
%%% @doc
%%%   System monitor: scheduler, RAM, and benchmarks throughput
%%%  sampled.
%%% @end
-module(ep_monitor).
-author("maximfca@gmail.com").

-behaviour(gen_server).

%% API
-export([
    start_link/0
]).

%% gen_server callbacks
-export([
    init/1,
    handle_call/3,
    handle_cast/2,
    handle_info/2,
    terminate/2
]).


-include_lib("kernel/include/logger.hrl").

-include("monitor.hrl").

-define(SERVER, ?MODULE).

-define(DEFAULT_TICK_INTERVAL_MS, 1000).


%%--------------------------------------------------------------------
%% @doc
%% Starts the server
-spec(start_link() ->
    {ok, Pid :: pid()} | ignore | {error, Reason :: term()}).
start_link() ->
    gen_server:start_link({local, ?SERVER}, ?MODULE, [], []).

%%%===================================================================
%%% gen_server callbacks

%% System monitor state
-record(state, {
    % bi-map of job processes to counters
    jobs = [] :: [{pid(), CRef :: reference(), Prev :: integer()}],
    % scheduler data saved from last call
    sched_data :: [{pos_integer(), integer(), integer()}],
    % number of normal schedulers
    normal :: pos_integer(),
    % number of dirty schedulers
    dcpu :: pos_integer(),
    %
    tick = ?DEFAULT_TICK_INTERVAL_MS :: pos_integer(),
    next_tick :: integer()
}).

init([]) ->
    % subscribe to job events
    erlang:process_flag(trap_exit, true),
    ep_event_handler:subscribe(?JOB_EVENT, job),
    %
    erlang:system_flag(scheduler_wall_time, true),
    Tick = ?DEFAULT_TICK_INTERVAL_MS,
    % start timing right now, and try to align for the middle of the interval
    %   to simplify collecting cluster-wide data
    % or not? Let's decide later.
    %Next = erlang:monotonic_time(millisecond) + Tick - erlang:system_time(millisecond) rem Tick + Tick div 2,
    Next = erlang:monotonic_time(millisecond) + Tick,
    erlang:start_timer(Next, self(), tick, [{abs, true}]),
    %% TODO: is it possible to avoid hacking over supervisor here?
    Jobs = [{Pid, ep_job:get_counters(Pid), 0} || {_, Pid, _, _} <- supervisor:which_children(ep_job_sup)],
    % init done
    {ok, #state{
        tick = Tick,
        jobs = Jobs,
        next_tick = Next + Tick,
        sched_data = lists:sort(erlang:statistics(scheduler_wall_time_all)),
        normal = erlang:system_info(schedulers),
        dcpu = erlang:system_info(dirty_cpu_schedulers)}
    }.

handle_call(_Request, _From, _State) ->
    error(badarg).

handle_cast(_Request, _State) ->
    error(badarg).

terminate(_Reason, _State) ->
    ep_event_handler:unsubscribe(?JOB_EVENT, job).

%%--------------------------------------------------------------------
%% @doc
%% Starts the server

handle_info({job, {started, Pid, _Code, CRef}}, #state{jobs = Jobs} = State) ->
    monitor(process, Pid),
    % emit system event for anyone willing to record this (e.g. benchmark_store process)
    {noreply, State#state{jobs = [{Pid, CRef, 0} | Jobs]}};

handle_info({'DOWN', _MRef, process, Pid, Reason}, #state{jobs = Jobs} = State) ->
    Reason =/= normal andalso Reason =/= shutdown andalso
        ?LOG_NOTICE("Job ~p exited with ~p", [Pid, Reason]),
    {noreply, State#state{jobs = lists:keydelete(Pid, 1, Jobs)}};

handle_info({timeout, _, tick}, State) ->
    {noreply, handle_tick(State)};

handle_info(_Info, _State) ->
    error(badarg).

%%%===================================================================
%%% Internal functions

handle_tick(#state{sched_data = Data, normal = Normal, dcpu = Dcpu} = State) ->
    NewSched = lists:sort(erlang:statistics(scheduler_wall_time_all)),
    {NU, DU, DioU} = fold_normal(Data, NewSched, Normal, Dcpu, 0, 0),
    % add benchmarking info
    {Jobs, UpdatedJobs} = lists:foldl(
        fun ({Pid, CRef, Prev}, {J, Save}) ->
            Cycles = atomics:get(CRef, 1),
            {[{Pid, Cycles - Prev} | J], [{Pid, CRef, Cycles} | Save]}
        end, {[], []}, State#state.jobs),
    %
    Sample = #monitor_sample{
        time = erlang:system_time(millisecond),
        memory_total = erlang:memory(total),
        memory_processes = erlang:memory(processes),
        memory_binary = erlang:memory(binary),
        memory_ets = erlang:memory(ets),
        sched_util = NU * 100,
        dcpu = DU * 100,
        dio = DioU * 100,
        processes = erlang:system_info(process_count),
        ports = erlang:system_info(port_count),
        ets = erlang:system_info(ets_count),
        jobs = Jobs},
    % notify subscribers
    gen_event:notify(?SYSTEM_EVENT, Sample),
    NextTick = State#state.next_tick + State#state.tick,
    erlang:start_timer(NextTick, self(), tick, [{abs, true}]),
    State#state{sched_data = NewSched, next_tick = NextTick, jobs = lists:reverse(UpdatedJobs)}.

%% Iterates over normal scheduler
fold_normal(Old, New, 0, Dcpu, AccActive, AccTotal) ->
    fold_dirty_cpu(Old, New, Dcpu, AccActive / AccTotal, 0, 0);
fold_normal([{N, OldActive, OldTotal} | Old],
    [{N, NewActive, NewTotal} | New], Normal, Dcpu, AccActive, AccTotal) ->
    fold_normal(Old, New, Normal - 1, Dcpu, AccActive + (NewActive - OldActive),
        AccTotal + (NewTotal - OldTotal)).

%% Iterates over DCPU
fold_dirty_cpu(Old, New, 0, NormalPct, AccActive, AccTotal) ->
    fold_dirty_io(Old, New, NormalPct, AccActive / AccTotal, 0, 0);
fold_dirty_cpu([{N, OldActive, OldTotal} | Old],
    [{N, NewActive, NewTotal} | New], Dcpu, NormalPct, AccActive, AccTotal) ->
    fold_dirty_cpu(Old, New, Dcpu - 1, NormalPct, AccActive + (NewActive - OldActive),
        AccTotal + (NewTotal - OldTotal)).

%% Remaining are dirty IO
fold_dirty_io([], [], NormalPct, DcpuPct, AccActive, AccTotal) ->
    {NormalPct, DcpuPct, AccActive / AccTotal};
fold_dirty_io([{N, OldActive, OldTotal} | Old],
    [{N, NewActive, NewTotal} | New], NormalPct, DcpuPct, AccActive, AccTotal) ->
    fold_dirty_io(Old, New, NormalPct, DcpuPct, AccActive + (NewActive - OldActive),
        AccTotal + (NewTotal - OldTotal)).
