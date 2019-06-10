%%%-------------------------------------------------------------------
%%% @author Maxim Fedorov <maximfca@gmail.com>
%%% @copyright (C) 2019, Maxim Fedorov
%%% @doc
%%%   System monitor: scheduler, RAM, and benchmarks throughput
%%%  sampled.
%%% @end
-module(monitor).
-author("maximfca@gmail.com").

-behaviour(gen_server).

%% API
-export([
    start_link/0,
    register_job/2,
    which_jobs/0,
    find_job/1
]).

%% gen_server callbacks
-export([
    init/1,
    handle_call/3,
    handle_cast/2,
    handle_info/2
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

%% @doc Used by job during initialisation stage. Registers a
%%  job as running, and an atomic counter for that job.
-spec register_job(pid(), reference()) ->
    {ok, {reference(), non_neg_integer()}} |
    {ok, {already_started, non_neg_integer()}} |
    {error, system_limit}.
register_job(Pid, CRef) ->
    gen_server:call(?SERVER, {register, Pid, CRef}).

%% @doc
%% Returns all currently running jobs
-spec which_jobs() -> [{pid(), UID :: integer()}].
which_jobs() ->
    gen_server:call(?SERVER, which_jobs).

%% @doc Finds job using unique ID
find_job(UID) ->
    lists:keyfind(UID, 2, which_jobs()).


%%%===================================================================
%%% gen_server callbacks

%% System monitor state
-record(state, {
    % next job receives this ID
    next_id = 1 :: integer(),
    % bi-map of job processes to counters
    jobs = [] :: [{pid(), CRef :: reference(), Prev :: integer(), UID :: integer()}],
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
    erlang:system_flag(scheduler_wall_time, true),
    % high priority process - for correct timing
    erlang:process_flag(priority, high),
    % start timing right now
    Tick = ?DEFAULT_TICK_INTERVAL_MS,
    Next = erlang:system_time(millisecond) + Tick,
    erlang:send_after(Tick, self(), tick),
    % init done
    {ok, #state{
        tick = Tick,
        next_tick = Next + Tick,
        sched_data = lists:sort(erlang:statistics(scheduler_wall_time_all)),
        normal = erlang:system_info(schedulers),
        dcpu = erlang:system_info(dirty_cpu_schedulers)}
    }.

handle_call({register, Pid, CRef}, _From, #state{jobs = Jobs, next_id = NextId} = State) ->
    case lists:keyfind(Pid, 1, Jobs) of
        false ->
            monitor(process, Pid),
            {reply, {ok, NextId},
                State#state{jobs = [{Pid, CRef, 0, NextId} | Jobs],
                    next_id = NextId + 1}};
        {Pid, _CRef, _, UID} ->
            {ok, {already_started, UID}}
    end;

handle_call(which_jobs, _From, State) ->
    {reply, [{Pid, UID} || {Pid, _, _, UID} <- State#state.jobs], State};

handle_call(_Request, _From, _State) ->
    error(badarg).

handle_cast(_Request, _State) ->
    error(badarg).

handle_info({'DOWN', _MRef, process, Pid, Reason}, #state{jobs = Jobs} = State) ->
    Reason =/= normal andalso Reason =/= shutdown andalso
        ?LOG_NOTICE("Job ~p exited with ~p", [Pid, Reason]),
    {noreply, State#state{jobs = lists:keydelete(Pid, 1, Jobs)}};
handle_info(tick, State) ->
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
        fun ({Pid, CRef, Prev, UID}, {J, Save}) ->
            Cycles = atomics:get(CRef, 1),
            {[{UID, Cycles - Prev} | J], [{Pid, CRef, Cycles, UID} | Save]}
        end, {[], []}, State#state.jobs),
    %
    Sample = #monitor_sample{
        time = erlang:system_time(millisecond),
        memory_total = erlang:memory(total),
        memory_processes = erlang:memory(processes),
        memory_binary = erlang:memory(binary),
        memory_ets = erlang:memory(ets),
        sched_util = NU,
        dcpu = DU,
        dio = DioU,
        processes = erlang:system_info(process_count),
        ports = erlang:system_info(port_count),
        ets = erlang:system_info(ets_count),
        jobs = Jobs},
    % notify subscribers
    gen_event:notify(system_event, Sample),
    %
    NextTick = schedule_send(State#state.next_tick, State#state.tick),
    %
    State#state{sched_data = NewSched, next_tick = NextTick, jobs = UpdatedJobs}.

schedule_send(NextTick, Tick) ->
    Now = erlang:system_time(millisecond),
    Next = NextTick + Tick,
    if Now < Next ->
            erlang:send_after(Next - Now, self(), tick),
            Next;
        true ->
            % time shift happened
            erlang:send_after(Tick, self(), tick),
            Now + Tick
    end.

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
