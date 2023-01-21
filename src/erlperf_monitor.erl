%%%-------------------------------------------------------------------
%%% @copyright (C) 2019-2023, Maxim Fedorov
%%% @doc
%%% System monitor: reports scheduler, RAM, and benchmarks.
%%%
%%% Monitor is started by default when {@link erlperf} starts
%%% as an application. Monitor is not started for ad-hoc
%%% benchmarking (e.g. command-line, unless verbose logging
%%% is requested).
%%%
%%% When started, the monitor provides periodic reports
%%% about Erlang VM state, and registered jobs performance.
%%% The reports are sent to all processes that joined
%%% `{erlperf_monitor, Node}' or `cluster_monitor' process
%%% group in `erlperf' scope.
%%%
%%% Reports can be received by any process, even the shell. Run
%%% the following example in `rebar3 shell' of `erlperf':
%%% ```
%%% (erlperf@ubuntu22)1> ok = pg:join(erlperf, cluster_monitor, self()).
%%% ok
%%% (erlperf@ubuntu22)2> erlperf:run(rand, uniform, []).
%%% 14976933
%%% (erlperf@ubuntu22)4> flush().
%%% Shell got {erlperf@ubuntu22,#{dcpu => 0.0,dio => 6.42619095979426e-4,
%%%                         ets => 44,jobs => [],memory_binary => 928408,
%%%                         memory_ets => 978056,
%%%                         memory_processes => 8603392,
%%%                         memory_total => 34952096,ports => 5,
%%%                         processes => 95,
%%%                         sched_util => 0.013187335960637163,
%%% '''
%%%
%%% Note that the monitor may report differently from the benchmark
%%% run results. It is running with lower priority and may be significantly
%%% affected by scheduler starvation, timing issues etc..
%%%
%%%
%%%
%%% @end
-module(erlperf_monitor).
-author("maximfca@gmail.com").

-behaviour(gen_server).

%% API
-export([
    start/0,
    start/1,
    start_link/0,
    start_link/1,
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


-type monitor_sample() :: #{
    time := integer(),
    node := node(),
    sched_util := float(),
    dcpu := float(),
    dio := float(),
    processes := integer(),
    ports := integer(),
    ets := integer(),
    memory_total := non_neg_integer(),
    memory_processes := non_neg_integer(),
    memory_binary := non_neg_integer(),
    memory_ets := non_neg_integer(),
    jobs => [{Job :: pid(), Cycles :: non_neg_integer()}]
}.
%% Monitoring report
%%
%% <ul>
%%   <li>`time': timestamp when the report is generates, wall clock, milliseconds</li>
%%   <li>`node': originating Erlang node name</li>
%%   <li>`sched_util': normal scheduler utilisation, percentage. See {@link scheduler:utilization/1}</li>
%%   <li>`dcpu': dirty CPU scheduler utilisation, percentage.</li>
%%   <li>`dio': dirty IO scheduler utilisation, percentage</li>
%%   <li>`processes': number of processes in the VM.</li>
%%   <li>`ports': number of ports in the VM.</li>
%%   <li>`ets': number of ETS tables created in the VM.</li>
%%   <li>`memory_total': total VM memory usage, see {@link erlang:memory/1}.</li>
%%   <li>`memory_processes': processes memory usage, see {@link erlang:system_info/1}.</li>
%%   <li>`memory_binary': binary memory usage.</li>
%%   <li>`memory_ets': ETS memory usage.</li>
%%   <li>`jobs': a map of job process identifier to the iterations surplus
%%    since last sample. If the sampling interval is default 1 second, the
%%    value of the map is "requests/queries per second" (RPS/QPS).</li>
%% </ul>

-type start_options() :: #{
    interval => pos_integer()
}.
%% Monitor startup options
%%
%% <ul>
%%   <li>`interval': monitoring interval, 1000 ms by default</li>
%% </ul>

-export_type([monitor_sample/0, start_options/0]).

%% @equiv start(#{interval => 1000})
-spec start() -> {ok, Pid :: pid()} | {error, Reason :: term()}.
start() ->
    start(#{interval => ?DEFAULT_TICK_INTERVAL_MS}).

%% @doc
%% Starts the monitor.
%%
%% `Options' are used to change the monitor behaviour.
%% <ul>
%%    <li>`interval': time, in milliseconds, to wait between sample collection</li>
%% </ul>
-spec start(Options :: start_options()) -> {ok, Pid :: pid()} | {error, Reason :: term()}.
start(Options) ->
    gen_server:start({local, ?MODULE}, ?MODULE, Options, []).

%% @equiv start_link(#{interval => 1000})
-spec(start_link() -> {ok, Pid :: pid()} | {error, Reason :: term()}).
start_link() ->
    start_link(#{interval => ?DEFAULT_TICK_INTERVAL_MS}).

%% @doc
%% Starts the monitor and links it to the current process. See {@link start/1}
%% for options description.
start_link(Options) ->
    gen_server:start_link({local, ?MODULE}, ?MODULE, Options, []).

%% @doc
%% Registers an {@link erlperf_job} to monitor.
%%
%% Running monitor queries every registered job, adding
%% the number of iterations performed by all workers of
%% that job to the report.
%% This API is intended to be used by {@link erlperf_job}
%% to enable VM monitoring while benchmarking.
%%
%% `Job' specifies job process identifier, it is only
%% used to detect when job is stopped, to stop reporting
%% counters for that job.
%%
%% `Handle' is the sampling handle, see {@link erlperf_job:handle/1}.
%%
%% `Initial' value should be provided when an existing job
%% is registered, to avoid reporting accumulated counter value
%% in the first report for that job.
%%
%% Always return `ok', even when monitor is not running.
-spec register(pid(), term(), non_neg_integer()) -> ok.
register(Job, Handle, Initial) ->
    gen_server:cast(?MODULE, {register, Job, Handle, Initial}).

%% @doc
%% Removes the job from monitoring.
%%
%% Stops reporting this job performance.
%%
%% `Job' is the process identifier of the job.
-spec unregister(pid()) -> ok.
unregister(Job) ->
    gen_server:cast(?MODULE, {unregister, Job}).

%%%===================================================================
%%% gen_server callbacks

%% System monitor state
-record(state, {
    % bi-map of job processes to counters
    jobs :: [{pid(), reference(), Handle :: erlperf_job:handle(), Prev :: integer()}],
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

%% @private
init(#{interval := Tick}) ->
    %% TODO: figure out if there is a way to find jobs after restart.
    %% ask a supervisor? but not all jobs are supervised...
    %% Jobs = [{Pid, erlperf_job:handle(Pid), 0} ||
    %%        {_, Pid, _, _} <- try supervisor:which_children(erlperf_job_sup) catch exit:{noproc, _} -> [] end],
    %% [monitor(process, Pid) || {Pid, _, _} <- Jobs],
    Jobs = [],
    %% enable scheduler utilisation calculation
    erlang:system_flag(scheduler_wall_time, true),
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

%% @private
handle_call(_Request, _From, _State) ->
    erlang:error(notsup).

%% @private
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

%% @private
handle_info({'DOWN', _MRef, process, Pid, _Reason}, #state{jobs = Jobs} = State) ->
    {noreply, State#state{jobs = lists:keydelete(Pid, 1, Jobs)}};

%% @private
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
        node => node(),
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
    % notify local & global subscribers
    Subscribers = pg:get_members(erlperf, {erlperf_monitor, node()}) ++ pg:get_members(erlperf, cluster_monitor),
    [Pid ! Sample || Pid <- Subscribers],
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
