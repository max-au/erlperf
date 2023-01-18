%%%-------------------------------------------------------------------
%%% @copyright (C) 2019-2023, Maxim Fedorov
%%% @doc
%%%   System monitor: scheduler, RAM, and benchmarks throughput
%%%  samples.
%%% @end
-module(erlperf_monitor).
-author("maximfca@gmail.com").

-behaviour(gen_server).

%% API
-export([
    start/0,
    start_link/0,
    register/3,
    unregister/1
]).

%% gen_server callbacks
-export([
    init/1,
    handle_call/3,
    handle_cast/2,
    handle_info/2
]).


-include_lib("kernel/include/logger.hrl").

-define(DEFAULT_TICK_INTERVAL_MS, 1000).

%% Monitoring sampling structure
-type monitor_sample() :: #{
    time => integer(),
    sched_util => float(),
    dcpu => float(),
    dio => float(),
    processes => integer(),
    ports => integer(),
    ets => integer(),
    memory_total => non_neg_integer(),
    memory_processes => non_neg_integer(),
    memory_binary => non_neg_integer(),
    memory_ets => non_neg_integer(),
    jobs => [{Job :: pid(), Cycles :: non_neg_integer()}]
}.

-export_type([monitor_sample/0]).

%%--------------------------------------------------------------------
%% @doc
%% Starts the server (unlinked, not supervised, used only for
%%  isolated BEAM runs)
-spec(start() -> {ok, Pid :: pid()} | {error, Reason :: term()}).
start() ->
    gen_server:start({local, ?MODULE}, ?MODULE, [], []).

%% @doc
%% Starts the server
-spec(start_link() -> {ok, Pid :: pid()} | {error, Reason :: term()}).
start_link() ->
    gen_server:start_link({local, ?MODULE}, ?MODULE, [], []).

%% @doc
%% Registers job to monitor (ignoring failures, as monitor may not be
%%  running).
-spec register(pid(), term(), non_neg_integer()) -> ok.
register(Job, Handle, Initial) ->
    gen_server:cast(?MODULE, {register, Job, Handle, Initial}).

%% @doc
%% Removes the job from monitoring (e.g. job has no workers running)
-spec unregister(pid()) -> ok.
unregister(Job) ->
    gen_server:cast(?MODULE, {unregister, Job}).

%%%===================================================================
%%% gen_server callbacks

%% System monitor state
-record(state, {
    % bi-map of job processes to counters
    jobs :: [{pid(), reference(), Handle :: erlperf_job:handle(), Prev :: integer()}]    ,
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
    %% subscribe to jobs starting up
    %% TODO: figure out if there is a way to find jobs after restart.
    %% ask a supervisor? but not all jobs are supervised...
    Jobs = [],
    %% Jobs = [{Pid, erlperf_job:handle(Pid), 0} ||
    %%        {_, Pid, _, _} <- try supervisor:which_children(erlperf_job_sup) catch exit:{noproc, _} -> [] end],
    %% [monitor(process, Pid) || {Pid, _, _} <- Jobs],
    %% enable scheduler utilisation calculation
    erlang:system_flag(scheduler_wall_time, true),
    Tick = ?DEFAULT_TICK_INTERVAL_MS,
    Next = erlang:monotonic_time(millisecond) + Tick,
    erlang:start_timer(Next, self(), tick, [{abs, true}]),
    {ok, #state{
        tick = Tick,
        jobs = Jobs,
        next_tick = Next,
        sched_data = lists:sort(erlang:statistics(scheduler_wall_time_all)),
        normal = erlang:system_info(schedulers),
        dcpu = erlang:system_info(dirty_cpu_schedulers)}
    }.

handle_call(_Request, _From, _State) ->
    erlang:error(notsup).

handle_cast({register, Job, Handle, Initial}, #state{jobs = Jobs} = State) ->
    MRef = monitor(process, Job),
    {noreply, State#state{jobs = [{Job, MRef, Handle, Initial} | Jobs]}};
handle_cast({unregister, Job}, #state{jobs = Jobs} = State) ->
    case lists:keyfind(Job, 1, Jobs) of
        {Job, MRef, _, _} ->
            demonitor(MRef, [flush]),
            {noreply, State#state{jobs = lists:keydelete(Job, 1, Jobs)}};
        false ->
            {noreply, State}
    end.

handle_info({'DOWN', _MRef, process, Pid, _Reason}, #state{jobs = Jobs} = State) ->
    {noreply, State#state{jobs = lists:keydelete(Pid, 1, Jobs)}};

handle_info({timeout, _, tick}, State) ->
    {noreply, handle_tick(State)}.

%%%===================================================================
%%% Internal functions

handle_tick(#state{sched_data = Data, normal = Normal, dcpu = Dcpu} = State) ->
    NewSched = lists:sort(erlang:statistics(scheduler_wall_time_all)),
    {NU, DU, DioU} = fold_normal(Data, NewSched, Normal, Dcpu, 0, 0),
    % add benchmarking info
    {Jobs, UpdatedJobs} = lists:foldl(
        fun ({Pid, MRef, Handle, Prev}, {J, Save}) ->
            Cycles =
                case erlperf_job:sample(Handle) of
                    C when is_integer(C) -> C;
                    undefined -> Prev %% job is stopped, race condition here
                end,
            {[{Pid, Cycles - Prev} | J], [{Pid, MRef, Handle, Cycles} | Save]}
        end, {[], []}, State#state.jobs),
    %
    Sample = #{
        time => erlang:system_time(millisecond),
        memory_total => erlang:memory(total),
        memory_processes => erlang:memory(processes),
        memory_binary => erlang:memory(binary),
        memory_ets => erlang:memory(ets),
        sched_util => NU * 100,
        dcpu => DU * 100,
        dio => DioU * 100,
        processes => erlang:system_info(process_count),
        ports => erlang:system_info(port_count),
        ets => erlang:system_info(ets_count),
        jobs => Jobs},
    % notify local subscribers
    [Pid ! Sample || Pid <- pg:get_members(erlperf, {erlperf_monitor, node()})],
    % notify global subscribers
    [Pid ! {node(), Sample} || Pid <- pg:get_members(erlperf, cluster_monitor)],
    %%
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
