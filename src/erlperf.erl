%%% @copyright (C) 2019-2023, Maxim Fedorov
%%% @doc
%%% Convenience APIs for benchmarking.
%%%
%%% This module implements following benchmarking modes:
%%% <ul>
%%%   <li>Continuous mode</li>
%%%   <li>Timed (low overhead) mode</li>
%%%   <li>Concurrency estimation (squeeze) mode</li>
%%% </ul>
%%%
%%% <h2>Continuous mode</h2>
%%% This is the default mode. Separate {@link erlperf_job} is started for
%%% each benchmark, iterating supplied runner in a tight loop,
%%% bumping a counter for each iteration of each worker. `erlperf' reads
%%% this counter every second, calculating the difference between current
%%% and previous value. This difference is called a <strong>sample</strong>.
%%%
%%% By default, `erlperf' collects 3 samples and stops, reporting the average.
%%% To give an example, if your function runs for 20 milliseconds, `erlperf'
%%% may capture samples with 48, 52 and 50 iterations. The average would be 50.
%%%
%%% This approach works well for CPU-bound calculations, but may produce
%%% unexpected results for slow functions taking longer than sample duration.
%%% For example, timer:sleep(2000) with default settings yields zero throughput.
%%% You can change the sample duration and the number of samples to take to
%%% avoid that.
%%%
%%% <h2>Timed mode</h2>
%%% In this mode `erlperf' loops your code a specified amount of times, measuring
%%% how long it took to complete. It is essentially what {@link timer:tc/3} does. This mode
%%% has slightly less overhead compared to continuous mode. This difference may be
%%% significant if you’re profiling low-level ERTS primitives.
%%%
%%% This mode does not support `concurrency' setting (concurrency locked to 1).
%%%
%%% <h2>Concurrency estimation mode</h2>
%%% In this mode `erlperf' attempts to estimate how concurrent the supplied
%%% runner code is. The run consists of multiple passes, increasing concurrency
%%% with each pass, and stopping when total throughput is no longer growing.
%%% This mode proves useful to find concurrency bottlenecks. For example, some
%%% functions may have limited throughput because they execute remote calls
%%% served by a single process. See {@link benchmark/3} for the detailed
%%% description.
%%%
%%%
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

%% compare/2 accepts code map, or just the runner code
-type code() :: erlperf_job:code_map() | erlperf_job:callable().
%% Convenience type used in `run/1,2,3' and `compare/2'.

%% node isolation options:
-type isolation() :: #{
    host => string()
}.
%% Node isolation settings.
%%
%% Currently, `host' selection is not supported.

-type run_options() :: #{
    concurrency => pos_integer(),
    sample_duration => pos_integer() | undefined,
    warmup => non_neg_integer(),
    samples => pos_integer(),
    cv => float(),
    priority => erlang:priority_level(),
    report => extended,
    isolation => isolation()
}.
%% Benchmarking mode selection and parameters of the benchmark run.
%%
%% <ul>
%%   <li>`concurrency': number of workers to run, applies only for the continuous
%%       benchmarking mode</li>
%%   <li>`cv': coefficient of variation. </li>
%%   <li>`isolation': request separate Erlang VM instance
%%       for each job. Some benchmarks may lead to internal VM structures corruption,
%%       or change global structures affecting other benchmarks when running in the
%%       same VM. `host' sub-option is currently ignored.</li>
%%   <li>`priority': sets the job controller process priority (defaults to `high').
%%       Running with `normal' or lower priority may prevent the controller from timely
%%       starting ot stopping workers.</li>
%%   <li>`report': applies only for continuous mode. Pass `extended' to get the list
%%       of actual samples, rather than average (useful for gathering advanced
%%       statistical metrics in the user code).</li>
%%   <li>`samples': how many samples to take before stopping (continuous mode), or
%%       how many iterations to do (timed mode). Default is 3, combined with the default
%%       1-second `sample_duration', it results in a 3 second continuous run</li>
%%   <li>`sample_duration': time, milliseconds, between taking iteration counter
%%       samples. Multiplied by `samples', this parameter defines the total benchmark
%%       run duration. Default is 1000 ms. Passing `undefined' engages timed run</li>
%%   <li>`warmup': how many extra samples are collected and discarded at the beginning
%%       of the continuous run. Does not apply to timed runs.</li>
%% </ul>

%% Concurrency test options
-type concurrency_test() :: #{
    threshold => pos_integer(),
    min => pos_integer(),
    max => pos_integer()
}.
%% Concurrency estimation mode options.
%%
%% <ul>
%%   <li>`min': initial number of workers, default is 1</li>
%%   <li>`max': maximum number of workers, defaults to `erlang:system_info(process_limit) - 1000'</li>
%%   <li>`threshold': stop concurrency run when adding this amount of workers does
%%     not result in further total throughput increase. Default is 3</li>
%% </ul>

%% Single run result: one or multiple samples (depending on report verbosity)
-type run_result() :: non_neg_integer() | [non_neg_integer()].
%% Benchmark results.
%%
%% For continuous mode, an average (arithmetic mean) of the collected samples,
%% or a list of all samples collected.
%% Timed mode returns elapsed time (microseconds).


%% Concurrency test result (non-verbose)
-type concurrency_result() :: {QPS :: non_neg_integer(), Concurrency :: non_neg_integer()}.
%% Basic concurrency estimation report
%%
%% Only the highest throughput run is reported.

%% Extended report returns all samples collected.
-type concurrency_test_result() :: concurrency_result() | {Max :: concurrency_result(), [concurrency_result()]}.
%% Extended concurrency estimation report
%%
%% Contains reports for all runs, starting from the minimum number of workers,
%% to the maximum achieved, plus `threshold' more.

-export_type([code/0, isolation/0, run_options/0, concurrency_test/0]).

%% Milliseconds, timeout for any remote node operation
-define(REMOTE_NODE_TIMEOUT, 10000).


%% @doc
%% Generic benchmarking suite, accepting multiple code maps, modes and options.
%%
%% `Codes' contain a list of code versions. Every element is a separate job that runs
%% in parallel with all other jobs. Same `RunOptions' are applied to all jobs.
%%
%% `ConcurrencyTestOpts' specifies options for concurrency estimation mode. Passing
%% `undefined' results in a continuous or a timed run. It is not supported to
%% run multiple jobs while doing a concurrency estimation run.
%%
%% Concurrency estimation run consists of multiple passes. First pass is done with
%% a `min' number of workers, subsequent passes are increasing concurrency by 1, until
%% `max' concurrency is reached, or total job iterations stop growing for `threshold'
%% consecutive passes. To give an example, if your code is not concurrent at all,
%% and you try to benchmark it with `threshold' set to 3, there will be 4 passes in
%% total: first with a single worker, then 3 more, demonstrating no throughput growth.
%%
%% In this mode, job is started once before the first pass. Subsequent passes only
%% change the concurrency. All other options passed in `RunOptions' are honoured. So,
%% if you set `samples' to 30, keeping default duration of a second, every single
%% pass will last for 30 seconds.
%% @end
-spec benchmark([erlperf_job:code_map()], RunOptions :: run_options(), undefined) -> run_result() | [run_result()];
               ([erlperf_job:code_map()], RunOptions :: run_options(), concurrency_test()) -> concurrency_test_result().
benchmark(Codes, #{isolation := _Isolation} = Options, ConcurrencyTestOpts) ->
    erlang:is_alive() orelse erlang:error(not_alive),
    %% isolation requested: need to rely on cluster_monitor and other distributed things.
    {Peers, Nodes} = prepare_nodes(length(Codes)),
    Opts = maps:remove(isolation, Options),
    try
        %% no timeout here (except that rpc itself could time out)
        Promises =
            [erpc:send_request(Node, erlperf, run, [Code, Opts, ConcurrencyTestOpts])
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
%% Comparison run: benchmark multiple jobs at the same time.
%%
%% A job is defined by either {@link erlperf_job:code_map()},
%% or just the runner {@link erlperf_job:callable(). callable}.
%% Example comparing {@link rand:uniform/0} %% performance
%% to {@link rand:mwc59/1}:
%% ```
%% (erlperf@ubuntu22)7> erlperf:compare([
%%     {rand, uniform, []},
%%     #{runner => "run(X) -> rand:mwc59(X).", init_runner => {rand, mwc59_seed, []}}
%% ], #{}).
%% [14823854,134121999]
%% '''
%%
%% See {@link benchmark/3} for `RunOptions' definition and return values.
-spec compare(Codes :: [code()], RunOptions :: run_options()) -> [run_result()].
compare(Codes, RunOptions) ->
    benchmark([code(Code) || Code <- Codes], RunOptions, undefined).

%% @private
%% @doc
%% Records call trace, so it could be used to benchmark later.
%% Experimental, do not use.
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

%% @doc
%% Runs a single benchmark for 3 seconds, returns average number of iterations per second.
%%
%% Accepts either a full {@link erlperf_job:code_map()}, or just the runner
%% {@link erlperf_job:callable(). callable}.
-spec run(code()) -> non_neg_integer().
run(Code) ->
    [Series] = benchmark([code(Code)], #{}, undefined),
    Series.

%% @doc
%% Runs a single benchmark job, returns average number of iterations per second.
%%
%% Accepts either a full {@link erlperf_job:code_map()}, or just the runner
%% {@link erlperf_job:callable(). callable}.
%% Equivalent of returning the first result of `run([Code], RunOptions)'.
-spec run(Code :: code(), RunOptions :: run_options()) -> run_result().
run(Code, RunOptions) ->
    [Series] = benchmark([code(Code)], RunOptions, undefined),
    Series.

%% @doc
%% Concurrency estimation run, or an alias for quick benchmarking of an MFA tuple.
%%
%% Attempt to find concurrency characteristics of the runner code,
%% see {@link benchmark/3} for a detailed description. Accepts either a full
%% {@link erlperf_job:code_map()}, or just the runner
%% {@link erlperf_job:callable(). callable}.
%%
%% When `Module' and `Function' are atoms, and `Args' is a list, this call is
%% equivalent of `run(Module, Function, Args)'.
-spec run(code(), run_options(), concurrency_test()) -> concurrency_test_result();
         (module(), atom(), [term()]) -> run_result().
run(Module, Function, Args) when is_atom(Module), is_atom(Function), is_list(Args) ->
    %% this typo is so common that I decided to have this as an unofficial API
    run({Module, Function, Args});
run(Code, RunOptions, ConTestOpts) ->
    [Series] = benchmark([code(Code)], RunOptions, ConTestOpts),
    Series.

%% @doc
%% Starts a new supervised job with the specified concurrency.
%%
%% Requires `erlperf' application to be running. Returns job
%% controller process identifier.
%% This function is designed for distributed benchmarking, when
%% jobs are started in different nodes, and monitored via
%% {@link erlperf_cluster_monitor}.
-spec start(code(), Concurrency :: non_neg_integer()) -> pid().
start(Code, Concurrency) ->
    {ok, Job} = supervisor:start_child(erlperf_job_sup, [code(Code)]),
    ok = erlperf_job:set_concurrency(Job, Concurrency),
    Job.

%% @doc
%% Timed benchmarking mode. Iterates the runner code `Count' times and returns
%% elapsed time in microseconds.
%%
%% This method has lower overhead compared to continuous benchmarking. It is
%% not supported to run multiple workers in this mode.
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