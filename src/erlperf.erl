%%% @copyright (C) 2019-2023, Maxim Fedorov
%%% @doc
%%%   Application API. Benchmark/squeeze implementation.
%%% @end
-module(erlperf).
-author("maximfca@gmail.com").

%% Public API for single-run simple benchmarking
%% Programmatic access.
-export([
    benchmark/3,
    compare/2,
    record/4,
    run/1,
    run/2,
    run/3,
    start/2,
    time/2
]).

%% accepted code variants
-type code() :: erlperf_job:code_map() | erlperf_job:callable().

%% node isolation options:
-type isolation() :: #{
    host => string()
}.

%% Single run options
-type run_options() :: #{
    % number of concurrently running workers (defaults to 1)
    % ignored when running concurrency test
    concurrency => pos_integer(),
    %% sampling interval: default is 1000 milliseconds (to measure QPS)
    %% 'undefined' duration is used as a flag for timed benchmarking
    sample_duration => pos_integer() | undefined,
    %% warmup samples: first 'warmup' cycles are ignored (defaults to 0)
    warmup => non_neg_integer(),
    %% number of samples to take, defaults to 3
    samples => pos_integer(),
    %% coefficient of variation, when supplied, at least 'samples'
    %%  samples must be within the specified coefficient
    %% experimental feature allowing to benchmark processes with
    %%  wildly jumping throughput
    cv => float(),
    %% sets the supervising process priority. Default is 'high',
    %% allowing test runner to be scheduled even under high scheduler
    %% utilisation (which is expected for a benchmark running many
    %% concurrent processes)
    priority => erlang:priority_level(),
    %% report form for single benchmark: when set to 'extended',
    %%  all non-warmup samples are returned as a list.
    %% When missing, only the average QPS is returned.
    report => extended,
    %% this run requires a fresh BEAM that must be stopped to
    %%  clear up the mess
    isolation => isolation()
}.

%% Concurrency test options
-type concurrency_test() :: #{
    %%  Detecting a local maximum. If maximum
    %%  throughput is reached with N concurrent workers, benchmark
    %%  continues for at least another 'threshold' more workers.
    %% Example: simple 'ok.' benchmark with 4-core CPU will stop
    %%  at 7 concurrent workers (as 5, 6 and 7 workers don't add
    %%  to throughput)
    threshold => pos_integer(),
    %% Minimum and maximum number of workers to try
    min => pos_integer(),
    max => pos_integer()
}.

%% Single run result: one or multiple samples (depending on report verbosity)
-type run_result() :: Throughput :: non_neg_integer() | [non_neg_integer()].

%% Concurrency test result (non-verbose)
-type concurrency_result() :: {QPS :: non_neg_integer(), Concurrency :: non_neg_integer()}.

%% Extended report returns all samples collected.
%% Basic report returns only maximum throughput achieved with
%%  amount of runners running at that time.
-type concurrency_test_result() :: concurrency_result() | {Max :: concurrency_result(), [concurrency_result()]}.

-export_type([isolation/0, run_options/0, concurrency_test/0]).

%% Milliseconds, timeout for any remote node operation
-define(REMOTE_NODE_TIMEOUT, 10000).


%% @doc
%% Generic execution engine. Supply multiple code versions, run options and either
%%  `undefined' for usual benchmarking, or squeeze mode settings for concurrency test.
%% @end
%% TODO: figure out what is wrong with this spec.
%% Somehow having run_result() in this spec makes Dialyzer to completely
%%  ignore option of concurrency_test_result() return.
%%-spec benchmark([erlperf_job:code()], run_options(), concurrency_test() | undefined) ->
%%    run_result() | [run_result()] | concurrency_test_result().
benchmark(Codes, #{isolation := _Isolation} = Options, ConOpts) ->
    erlang:is_alive() orelse erlang:error(not_alive),
    %% isolation requested: need to rely on cluster_monitor and other distributed things.
    {Peers, Nodes} = prepare_nodes(length(Codes)),
    Opts = maps:remove(isolation, Options),
    try
        %% no timeout here (except that rpc itself could time out)
        Promises =
            [erpc:send_request(Node, erlperf, run, [Code, Opts, ConOpts])
                || {Node, Code} <- lists:zip(Nodes, Codes)],
        %% now wait for everyone to respond
        [erpc:receive_response(Promise) || Promise <- Promises]
    catch
        error:{exception, Reason, Stack} ->
            erlang:raise(error, Reason, Stack)
    after
        stop_nodes(Peers, Nodes)
    end;

%% no isolation requested, do normal in-BEAM test
benchmark(Codes, Options, ConOpts) ->
    %% elevate priority to reduce timer skew
    SetPrio = maps:get(priority, Options, high),
    PrevPriority = process_flag(priority, SetPrio),
    Jobs = start_jobs(Codes, []),
    {JobPids, Samples, _} = lists:unzip3(Jobs),
    try
        benchmark(JobPids, Options, ConOpts, Samples)
    after
        stop_jobs(Jobs),
        process_flag(priority, PrevPriority)
    end.

%% @doc
%% Comparison run: starts several jobs and measures throughput for
%%  all of them at the same time.
%% All job options are honoured, and if there is isolation applied,
%%  every job runs its own node.
-spec compare([code()], run_options()) -> [run_result()].
compare(Codes, RunOptions) ->
    benchmark([code(Code) || Code <- Codes], RunOptions, undefined).

%% @doc
%% Records call trace, so it could be used to benchmark later.
-spec record(module(), atom(), non_neg_integer(), pos_integer()) ->
    [[{module(), atom(), [term()]}]].
record(Module, Function, Arity, TimeMs) ->
    TracerPid = spawn_link(fun rec_tracer/0),
    TraceSpec = [{'_', [], []}],
    MFA = {Module, Function, Arity},
    erlang:trace_pattern(MFA, TraceSpec, [global]),
    erlang:trace(all, true, [call, {tracer, TracerPid}]),
    receive after TimeMs -> ok end,
    erlang:trace(all, false, [call]),
    erlang:trace_pattern(MFA, false, [global]),
    TracerPid ! {stop, self()},
    receive
        {data, Samples} ->
            Samples
    end.

%% @doc Simple case.
%%  Runs a single benchmark, and returns a steady QPS number.
%%  Job specification may include suite &amp; worker init parts, suite cleanup,
%%  worker code, job name and identifier (id).
-spec run(code()) -> non_neg_integer().
run(Code) ->
    [Series] = benchmark([code(Code)], #{}, undefined),
    Series.

%% @doc
%% Single throughput measurement cycle.
%% Additional options are applied.
-spec run(code(), run_options()) -> run_result().
run(Code, RunOptions) ->
    [Series] = benchmark([code(Code)], RunOptions, undefined),
    Series.

%% @doc
%% Concurrency measurement run.
-spec run(code() | module(), run_options() | atom(), concurrency_test() | [term()]) ->
    run_result() | concurrency_test_result().
run(Module, Function, Args) when is_atom(Module), is_atom(Function), is_list(Args) ->
    %% this typo is so common that I decided to have this as an unofficial API
    run({Module, Function, Args});
run(Code, RunOptions, ConTestOpts) ->
    [Series] = benchmark([code(Code)], RunOptions, ConTestOpts),
    Series.

%% @doc
%% Starts a new continuously running job with the specified concurrency.
%% Requires `erlperf' application to be started.
-spec start(code(), Concurrency :: non_neg_integer()) -> pid().
start(Code, Concurrency) ->
    {ok, Job} = supervisor:start_child(erlperf_job_sup, [code(Code)]),
    ok = erlperf_job:set_concurrency(Job, Concurrency),
    Job.

%% @doc
%% Timed benchmarking, runs the code Count times and returns
%%  time in microseconds it took to execute the code.
-spec time(code(), Count :: non_neg_integer()) -> TimeUs :: non_neg_integer().
time(Code, Count) ->
    [Series] = benchmark([code(Code)], #{samples => Count, sample_duration => undefined}, undefined),
    Series.

%%===================================================================
%% Codification: translate from {M, F, A} to #{runner => ...} map
code(#{runner := _Runner} = Code) ->
    Code;
code({M, F, A}) when is_atom(M), is_atom(F), is_list(A) ->
    #{runner => {M, F, A}};
code(Fun) when is_function(Fun) ->
    #{runner => Fun};
code(Text) when is_list(Text) ->
    #{runner => Text}.

%%===================================================================
%% Benchmarking itself

%% OTP 25 support
-dialyzer({no_missing_calls, start_node/1}).
-compile({nowarn_deprecated_function, [{slave, start_link, 3}, {slave, stop, 1}]}).
-compile({nowarn_removed, [{slave, start_link, 3}, {slave, stop, 1}]}).

start_node({module, peer}) ->
    {ok, _Peer, _Node} = peer:start_link(#{name => peer:random_name()});
start_node({error, nofile}) ->
    OsPid = os:getpid(),
    [_, HostString] = string:split(atom_to_list(node()), "@"),
    Host = list_to_atom(HostString),
    Args = "-setcookie " ++ atom_to_list(erlang:get_cookie()),
    Uniq = erlang:unique_integer([positive]),
    NodeId = list_to_atom(lists:concat(["job-", Uniq, "-", OsPid])),
    {ok, Node} = slave:start_link(Host, NodeId, Args),
    {ok, undefined, Node}.

prepare_nodes(HowMany) ->
    %% start 'erlperf' parts on all peers
    %% Cannot do this via "code:add_path" because actual *.beam files are
    %%  parts of the binary escript.
    _ = application:load(erlperf),
    {ok, ModNames} = application:get_key(erlperf, modules),
    Modules = [{Mod, _Bin, _Path} = code:get_object_code(Mod) || Mod <- ModNames],
    PeerPresent = code:ensure_loaded(peer),
    %% start multiple nodes
    lists:unzip([begin
         {ok, Peer, Node} =  start_node(PeerPresent),
         [{module, Mod} = erpc:call(Node, code, load_binary, [Mod, Path, Bin], ?REMOTE_NODE_TIMEOUT)
             || {Mod, Bin, Path} <- Modules],
         {ok, _PgPid} = erpc:call(Node, pg, start, [erlperf]),
         {ok, _MonPid} = erpc:call(Node, erlperf_monitor, start, []),
         {Peer, Node}
     end || _ <- lists:seq(1, HowMany)]).

stop_nodes([undefined | _], Nodes) ->
    [slave:stop(Node) || Node <- Nodes];
stop_nodes(Peers, _Nodes) ->
    [peer:stop(Peer) || Peer <- Peers].

start_jobs([], Jobs) ->
    lists:reverse(Jobs);
start_jobs([Code | Codes], Jobs) ->
    try
        {ok, Pid} = erlperf_job:start(Code),
        Sample = erlperf_job:handle(Pid),
        MonRef = monitor(process, Pid),
        start_jobs(Codes, [{Pid, Sample, MonRef} | Jobs])
    catch Class:Reason:Stack ->
        %% stop jobs that were started
        stop_jobs(Jobs),
        erlang:raise(Class, Reason, Stack)
    end.

stop_jobs(Jobs) ->
    %% do not use gen:stop/1,2 or sys:terminate/2,3 here, as they spawn process running
    %%  with normal priority, and they don't get scheduled fast enough when there is severe
    %%  lock contention
    WaitFor = [begin erlperf_job:request_stop(Pid), {Pid, Mon} end || {Pid, _, Mon} <- Jobs, is_process_alive(Pid)],
    %% now wait for all monitors to fire
    [receive {'DOWN', Mon, process, Pid, _R} -> ok end || {Pid, Mon} <- WaitFor].

-define(DEFAULT_SAMPLE_DURATION, 1000).

%% low-overhead benchmark
benchmark(Jobs, #{sample_duration := undefined, samples := Samples}, undefined, _Handles) ->
    Proxies = [spawn_monitor(fun () -> exit({success, erlperf_job:measure(Job, Samples)}) end)
        || Job <- Jobs],
    [case Res of
         {success, Success} -> Success;
         Error -> erlang:error(Error)
     end || Res <- multicall_result(Proxies, [])];

%% continuous benchmark
benchmark(Jobs, Options, undefined, Handles) ->
    Concurrency = maps:get(concurrency, Options, 1),
    [ok = erlperf_job:set_concurrency(Job, Concurrency) || Job <- Jobs],
    perform_benchmark(Jobs, Handles, Options);

%% squeeze test - concurrency benchmark
benchmark(Jobs, Options, ConOpts, Handles) ->
    Min = maps:get(min, ConOpts, 1),
    perform_squeeze(Jobs, Handles, Min, [], {0, 0}, Options,
        ConOpts#{max => maps:get(max, ConOpts, erlang:system_info(process_limit) - 1000)}).

%% QPS considered stable when:
%%  * 'warmup' cycles have passed
%%  * 'samples' cycles have been received
%%  * (optional) for the last 'samples' cycles coefficient of variation did not exceed 'cv'
perform_benchmark(Jobs, Handles, Options) ->
    Interval = maps:get(sample_duration, Options, ?DEFAULT_SAMPLE_DURATION),
    % warmup: intended to figure out sleep method (whether to apply busy_wait immediately)
    NowTime = os:system_time(millisecond),
    SleepMethod = warmup(maps:get(warmup, Options, 0), NowTime, NowTime + Interval, Interval, sleep),
    % find all options - or take their defaults, TODO: maybe do that at a higher level?
    JobMap = maps:from_list([{J, []} || J <- Jobs]),
    CV = maps:get(cv, Options, undefined),
    SampleCount = maps:get(samples, Options, 3),
    Report = maps:get(report, Options, false),
    % remember initial counters in Before
    StartedAt = os:system_time(millisecond),
    Before = [[erlperf_job:sample(Handle)] || Handle <- Handles],
    Samples = measure_impl(JobMap, Before, Handles, StartedAt, StartedAt + Interval, Interval,
        SleepMethod, SampleCount, CV),
    report_benchmark(Samples, Report).

%% warmup procedure: figure out if sleep/4 can work without falling back to busy wait
warmup(0, _LastSampleTime, _NextSampleTime, _Interval, Method) ->
    Method;
warmup(Count, LastSampleTime, NextSampleTime, Interval, Method) ->
    SleepFor = NextSampleTime - LastSampleTime,
    NextMethod = sleep(Method, SleepFor, NextSampleTime, #{}),
    NowTime = os:system_time(millisecond),
    warmup(Count - 1, NowTime, NextSampleTime + Interval, Interval, NextMethod).

measure_impl(_Jobs, Before, _Handles, _LastSampleTime, _NextSampleTime, _Interval, _SleepMethod, 0, undefined) ->
    normalise(Before);

measure_impl(Jobs, Before, Handles, LastSampleTime, NextSampleTime, Interval, SleepMethod, 0, CV) ->
    %% Complication: some jobs may need a long time to stabilise compared to others.
    %% Decision: wait for all jobs to stabilise (could wait for just one?)
    case
        lists:any(
            fun (Samples) ->
                Normal = normalise_series(Samples),
                Len = length(Normal),
                Mean = lists:sum(Normal) / Len,
                StdDev = math:sqrt(lists:sum([(S - Mean) * (S - Mean) || S <- Normal]) / (Len - 1)),
                StdDev / Mean > CV
            end,
            Before
        )
    of
        false ->
            normalise(Before);
        true ->
            % imitate queue - drop last sample, push another in the head
            TailLess = [lists:droplast(L) || L <- Before],
            measure_impl(Jobs, TailLess, Handles, LastSampleTime, NextSampleTime + Interval,
                Interval, SleepMethod, 1, CV)
    end;

%% LastSampleTime: system time of the last sample
%% NextSampleTime: system time when to take the next sample
%% Interval: to calculate the next NextSampleTime
%% Count: how many more samples to take
%% CV: coefficient of variation
measure_impl(Jobs, Before, Handles, LastSampleTime, NextSampleTime, Interval, SleepMethod, Count, CV) ->
    SleepFor = NextSampleTime - LastSampleTime,
    NextSleepMethod = sleep(SleepMethod, SleepFor, NextSampleTime, Jobs),
    NowTime = os:system_time(millisecond),
    Counts = [erlperf_job:sample(Handle) || Handle <- Handles],
    measure_impl(Jobs, merge(Counts, Before), Handles, NowTime, NextSampleTime + Interval, Interval,
        NextSleepMethod, Count - 1, CV).

%% ERTS real-time properties are easily broken by lock contention (e.g. ETS misuse)
%% When it happens, even the 'max' priority process may not run for an extended
%% period of time.

sleep(sleep, SleepFor, _WaitUntil, Jobs) when SleepFor > 0 ->
    receive
        {'DOWN', _Ref, process, Pid, Reason} when is_map_key(Pid, Jobs) ->
            erlang:error({benchmark, {'EXIT', Pid, Reason}})
    after SleepFor ->
        sleep
    end;
sleep(_Mode, _SleepFor, WaitUntil, Jobs) ->
    busy_wait(WaitUntil, Jobs).

%% When sleep detects significant difference in the actual sleep time vs. expected,
%% loop is switched to the busy wait.
%% Once switched to busy wait, erlperf stays there until the end of the test.
busy_wait(WaitUntil, Jobs) ->
    receive
        {'DOWN', _Ref, process, Pid, Reason} when is_map_key(Pid, Jobs) ->
            erlang:error({benchmark, {'EXIT', Pid, Reason}})
    after 0 ->
        case os:system_time(millisecond) of
            Now when Now > WaitUntil ->
                busy_wait;
            _ ->
                busy_wait(WaitUntil, Jobs)
        end
    end.

merge([], []) ->
    [];
merge([M | T], [H | T2]) ->
    [[M | H] | merge(T, T2)].

normalise(List) ->
    [normalise_series(L) || L <- List].

normalise_series([_]) ->
    [];
normalise_series([S, F | Tail]) ->
    [S - F | normalise_series([F | Tail])].

report_benchmark(Samples, extended) ->
    Samples;
report_benchmark(SamplesList, false) ->
    [lists:sum(Samples) div length(Samples) || Samples <- SamplesList].

%% Determine maximum throughput by measuring multiple times with different concurrency.
%% Test considered complete when either:
%%  * maximum number of workers reached
%%  * last 'threshold' added workers did not increase throughput
perform_squeeze(_Pid, _Handle, Current, History, QMax, Options, #{max := Max}) when Current > Max ->
    % reached max allowed schedulers, exiting
    report_squeeze(QMax, History, Options);

perform_squeeze(Jobs, Handles, Current, History, QMax, Options, ConOpts) ->
    ok = erlperf_job:set_concurrency(hd(Jobs), Current),
    [QPS] = perform_benchmark(Jobs, Handles, Options),
    NewHistory = [{QPS, Current} | History],
    case maxed(QPS, Current, QMax, maps:get(threshold, ConOpts, 3))  of
        true ->
            % QPS are either stable or decreasing
            report_squeeze(QMax, NewHistory, Options);
        NewQMax ->
            % need more workers
            perform_squeeze(Jobs, Handles, Current + 1, NewHistory, NewQMax, Options, ConOpts)
    end.

report_squeeze(QMax, History, Options) ->
    case maps:get(report, Options, undefined) of
        extended ->
            [{QMax, History}];
        _ ->
            [QMax]
    end.

maxed(QPS, Current, {Q, _}, _) when QPS > Q ->
    {QPS, Current};
maxed(_, Current, {_, W}, Count) when Current - W > Count ->
    true;
maxed(_, _, QMax, _) ->
    QMax.


multicall_result([], Acc) ->
    lists:reverse(Acc);
multicall_result([{Pid, Ref} | Proxies], Acc) ->
    receive
        {'DOWN', Ref, process, Pid, Result} ->
            multicall_result(Proxies, [Result | Acc])
    end.

%%%===================================================================
%%% Tracer process, uses heap to store tracing information.
rec_tracer() ->
    process_flag(message_queue_data, off_heap),
    tracer_loop([]).

-spec tracer_loop([{module(), atom(), [term()]}]) -> ok.
tracer_loop(Trace) ->
    receive
        {trace, _Pid, call, MFA} ->
            tracer_loop([MFA | Trace]);
        {stop, Control} ->
            Control ! {data, Trace},
            ok
    end.