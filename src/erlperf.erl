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
%%% this counter every second (or `sample_duration'), calculating the
%%% difference between current and previous value. This difference is
%%% called a <strong>sample</strong>.
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

%% Exported for testing purposes only.
-export([report_stats/1]).

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
    sample_duration => pos_integer() | undefined | {timed, pos_integer()},
    warmup => non_neg_integer(),
    samples => pos_integer(),
    cv => float() | undefined,
    priority => erlang:priority_level(),
    report => basic | extended | full,
    isolation => isolation()
}.
%% Benchmarking mode selection and parameters of the benchmark run.
%%
%% <ul>
%%   <li>`concurrency': number of workers to run, applies only for the continuous
%%       benchmarking mode</li>
%%   <li>`cv': coefficient of variation. Acceptable standard deviation for the test
%%       to conclude. Not applicable for timed mode. When the value is set, benchmark
%%       will continue running until standard deviation for the last collected `samples'
%%       divided by average value (arithmetic mean) is smaller than `cv' specified.</li>
%%   <li>`isolation': request separate Erlang VM instance
%%       for each job. Some benchmarks may lead to internal VM structures corruption,
%%       or change global structures affecting other benchmarks when running in the
%%       same VM. `host' sub-option is currently ignored.</li>
%%   <li>`priority': sets the job controller process priority (defaults to `high').
%%       Running with `normal' or lower priority may prevent the controller from timely
%%       starting ot stopping workers.</li>
%%   <li>`report': applies only for continuous mode. `basic' report contains only
%%       the average value. Specify `extended' to get the list of actual samples,
%%       to calculate exotic statistics. Pass `full' to receive full report, including
%%       benchmark settings and extra statistics for continuous mode - minimum, maximum,
%%       average, median and 99th percentile (more metrics may be added in future
%%       releases)</li>
%%   <li>`samples': number of measurements to take. Default is 3. For continuous mode
%%       it results in a 3 second run, when `sample_duration' is set to default 1000 ms.
%%       </li>
%%   <li>`sample_duration': time, milliseconds, between taking iteration counter
%%       samples. Multiplied by `samples', this parameter defines the total benchmark
%%       run duration. Default is 1000 ms. Passing `{timed, Counter}` engages timed
%%       mode with `Counter' iterations taken `samples' times</li>
%%   <li>`warmup': how many extra samples are collected and discarded at the beginning
%%       of the continuous run</li>
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
%% Only the highest throughput run is reported. `Concurrency' contains the number of
%% concurrently running workers when the best result is achieved.

%% Extended report returns all samples collected.
-type concurrency_test_result() :: concurrency_result() | {Max :: concurrency_result(), [concurrency_result()]}.
%% Concurrency estimation mode result
%%
%% Extended report contains results for all runs, starting from the minimum number
%% of workers, to the highest throughput detected, plus up to `threshold' more.

-type system_information() :: #{
    os := {unix | win32, atom()},
    system_version := string(),
    cpu => string()
}.
%% System information, as returned by {@link erlang:system_info/1}
%% May also contain CPU model name on supported operating systems.

-type run_statistics() :: #{
    average => non_neg_integer(),
    variance => float(),
    stddev => float(),
    median => non_neg_integer(),
    p99 => non_neg_integer(),
    best => non_neg_integer(),
    worst => non_neg_integer(),
    samples => [non_neg_integer()],
    time => non_neg_integer(),
    iteration_time => non_neg_integer()
}.
%% Results reported by a single benchmark run.
%%
%% <ul>
%%   <li>`best': highest throughput for continuous mode, or lowest time for timed</li>
%%   <li>`worst': lowest throughput, or highest time</li>
%%   <li>`average': arithmetic mean, iterations for continuous
%%        mode and microseconds for timed</li>
%%   <li>`stddev': standard deviation</li>
%%   <li>`median': median (50% percentile)</li>
%%   <li>`p99': 99th percentile</li>
%%   <li>`samples': raw samples from the run, monotonic counter for
%%        continuous mode, and times measured for timed run</li>
%%   <li>`time': total benchmark duration (us), may exceed `sample' * `sample_duration'
%%       when `cv' is specified and results are not immediately stable</li>
%%   <li>`iteration_time': approximate single iteration time (of one runner)</li>
%% </ul>

-type report() :: #{
    mode := timed | continuous | concurrency,
    result := run_statistics(),
    history => [{Concurrency :: pos_integer(), Result :: run_statistics()}],
    code := erlperf_job:code_map(),
    run_options := run_options(),
    concurrency_options => concurrency_test(),
    system => system_information(),
    sleep => sleep | busy_wait
}.
%% Full benchmark report, containing all collected samples and statistics
%%
%% <ul>
%%   <li>`mode': benchmark run mode</li>
%%   <li>`result': benchmark result. Concurrency estimation mode contains
%%       the best result (with the highest average throughput recorded)</li>
%%   <li>`code': original code</li>
%%   <li>`run_options': full set of options, with all defaults filled in</li>
%%   <li>`system': information about the system benchmark is running on</li>
%%   <li>`history': returned only for concurrency estimation mode,
%%       contains a list of all runs with their results</li>
%%   <li>`concurrency_options': returned only for concurrency estimation
%%       mode, with all defaults filled in</li>
%%   <li>`sleep': method used for waiting for a specified amount of time.
%%       Normally set to `sleep', but may be reported as `busy_wait' if
%%       `erlperf' scheduling is impacted by lock contention or another
%%       problem preventing it from using precise timing</li>
%% </ul>

-export_type([code/0, isolation/0, run_options/0, concurrency_test/0, report/0,
    system_information/0, run_statistics/0]).

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
-spec benchmark([erlperf_job:code_map()], RunOptions :: run_options(), undefined) -> run_result() | [run_result()] | [report()];
               ([erlperf_job:code_map()], RunOptions :: run_options(), concurrency_test()) -> concurrency_test_result() | [report()].
benchmark(Codes, #{isolation := Isolation} = RunOptions, ConcurrencyTestOpts) ->
    erlang:is_alive() orelse erlang:error(not_alive),
    %% isolation requested: need to rely on cluster_monitor and other distributed things.
    {Peers, Nodes} = prepare_nodes(length(Codes)),
    Opts = maps:remove(isolation, RunOptions),
    try
        %% no timeout here (except that rpc itself could time out)
        Promises =
            [erpc:send_request(Node, erlperf, run, [Code, Opts, ConcurrencyTestOpts])
                || {Node, Code} <- lists:zip(Nodes, Codes)],
        %% now wait for everyone to respond
        Reports = [erpc:receive_response(Promise) || Promise <- Promises],
        %% if full reports were requested, restore isolation flag
        case maps:get(report, RunOptions, basic) of
            full ->
                [maps:update_with(run_options, fun(RO) -> RO#{isolation => Isolation} end, Report)
                    || Report <- Reports];
            _ ->
                Reports
        end
    catch
        error:{exception, Reason, Stack} ->
            erlang:raise(error, Reason, Stack)
    after
        stop_nodes(Peers, Nodes)
    end;

%% foolproofing
benchmark([_, _ | _], _RunOptions, #{}) ->
    erlang:error(not_supported);

%% No isolation requested.
%% This is the primary entry point for all benchmark jobs.
benchmark(Codes, RunOptions0, ConOpts0) ->
    %% fill in all missing defaults
    ConOpts = concurrency_mode_defaults(ConOpts0),
    #{report := ReportType, priority := SetPrio} = RunOptions = run_options_defaults(RunOptions0),
    %% elevate priority to reduce timer skew
    PrevPriority = process_flag(priority, SetPrio),
    Jobs = start_jobs(Codes, []),
    {JobPids, Handles, _} = lists:unzip3(Jobs),
    Reports =
        try
            benchmark_impl(JobPids, RunOptions, ConOpts, Handles)
        after
            stop_jobs(Jobs),
            process_flag(priority, PrevPriority)
        end,
    %% generate statistical information from the samples returned
    report(ReportType, Codes, Reports).

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
-spec compare(Codes :: [code()], RunOptions :: run_options()) -> [run_result()] | [report()].
compare(Codes, RunOptions) ->
    benchmark([code(Code) || Code <- Codes], RunOptions, undefined).

%% @doc
%% Runs a single benchmark for 3 seconds, returns average number of iterations per second.
%%
%% Accepts either a full {@link erlperf_job:code_map()}, or just the runner
%% {@link erlperf_job:callable(). callable}.
-spec run(code()) -> non_neg_integer().
run(Code) ->
    [Report] = benchmark([code(Code)], #{}, undefined),
    Report.

%% @doc
%% Runs a single benchmark job, returns average number of iterations per second,
%% or a full report.
%%
%% Accepts either a full {@link erlperf_job:code_map()}, or just the runner
%% {@link erlperf_job:callable(). callable}.
%% Equivalent of returning the first result of `run([Code], RunOptions)'.
-spec run(Code :: code(), RunOptions :: run_options()) -> run_result() | report().
run(Code, RunOptions) ->
    [Report] = benchmark([code(Code)], RunOptions, undefined),
    Report.

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
-spec run(code(), run_options(), concurrency_test()) -> concurrency_test_result() | report();
         (module(), atom(), [term()]) -> QPS :: non_neg_integer().
run(Module, Function, Args) when is_atom(Module), is_atom(Function), is_list(Args) ->
    %% this typo is so common that I decided to have this as an unofficial API
    run({Module, Function, Args});
run(Code, RunOptions, ConTestOpts) ->
    [Report] = benchmark([code(Code)], RunOptions, ConTestOpts),
    Report.

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
    [Report] = benchmark([code(Code)], #{samples => Count, sample_duration => undefined}, undefined),
    Report.

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

%% ===================================================================
%% Implementation details
concurrency_mode_defaults(undefined) ->
    undefined;
concurrency_mode_defaults(ConOpts) ->
    maps:merge(#{min => 1, max => erlang:system_info(process_limit) - 1000, threshold => 3}, ConOpts).

run_options_defaults(RunOptions) ->
    maps:merge(#{
        concurrency => 1,
        sample_duration => 1000,
        warmup => 0,
        samples => 3,
        cv => undefined,
        priority => high,
        report => basic},
        RunOptions).

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
        Handle = erlperf_job:handle(Pid),
        MonRef = monitor(process, Pid),
        start_jobs(Codes, [{Pid, Handle, MonRef} | Jobs])
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

%% Benchmark implementation. Always returns a full report (post-processing will dumb it down if needed).

%% Timed mode,backwards compatibility conversion
benchmark_impl(Jobs, #{sample_duration := undefined, samples := Samples} = RunOptions, undefined, Handles) ->
    benchmark_impl(Jobs, RunOptions#{sample_duration => {timed, Samples}, samples => 1}, undefined, Handles);

%% timed mode
benchmark_impl(Jobs, #{sample_duration := {timed, Duration}, samples := Samples, warmup := Warmup} = RunOptions, undefined, _Handles) ->
    Proxies = [
        spawn_monitor(
            fun () ->
                _Discarded = [erlperf_job:measure(Job, Duration) || _ <- lists:seq(1, Warmup)],
                Times = [erlperf_job:measure(Job, Duration) || _ <- lists:seq(1, Samples)],
                exit({success, Times})
            end)
        || Job <- Jobs],
    [case Res of
         {success, TimesUs} ->
             #{mode => timed, result => #{samples => TimesUs}, run_options => RunOptions};
         Error ->
             erlang:error(Error)
     end || Res <- multicall_result(Proxies, [])];

%% Continuous mode
%% QPS considered stable when:
%%  * 'warmup' done
%%  * 'samples' received
%%  * (optional) for the last 'samples' standard deviation must not exceed 'cv'
benchmark_impl(Jobs, #{sample_duration := Interval, cv := CV, samples := SampleCount,
    warmup := Warmup, concurrency := Concurrency} = RunOptions, undefined, Handles) ->
    %% TODO: turn the next sequential call into a multi-call, to make warmup time fair
    [ok = erlperf_job:set_concurrency(Job, Concurrency) || Job <- Jobs],
    %% warmup: intended to figure out sleep method (whether to apply busy_wait immediately)
    NowTime = os:system_time(millisecond),
    SleepMethod = warmup(Warmup, NowTime, NowTime + Interval, Interval, sleep),
    %% remember initial counters in Before
    Before = [[erlperf_job:sample(Handle)] || Handle <- Handles],
    StartedAt = os:system_time(millisecond),
    {Samples, TimerSkew, FinishedAt} = measure_impl(Before, Handles, StartedAt, StartedAt + Interval, Interval,
        SleepMethod, SampleCount, CV),
    Time = FinishedAt - StartedAt,
    [#{mode => continuous, result => #{samples => lists:reverse(S), time => Time * 1000},
        run_options => RunOptions, sleep => TimerSkew}
        || S <- Samples];

%% squeeze test - concurrency benchmark
benchmark_impl(Jobs, RunOptions, #{min := Min} = ConOpts, Handles) ->
    [estimate_concurrency(Jobs, RunOptions, ConOpts, Handles, Min, [], {0, 0})].

%% warmup procedure: figure out if sleep/4 can work without falling back to busy wait
warmup(0, _LastSampleTime, _NextSampleTime, _Interval, Method) ->
    Method;
warmup(Count, LastSampleTime, NextSampleTime, Interval, Method) ->
    SleepFor = NextSampleTime - LastSampleTime,
    NextMethod = sleep(Method, SleepFor, NextSampleTime),
    NowTime = os:system_time(millisecond),
    warmup(Count - 1, NowTime, NextSampleTime + Interval, Interval, NextMethod).

%% collected all samples, CV is not defined
measure_impl(Before, _Handles, LastSampleTime, _NextSampleTime, _Interval, SleepMethod, 0, undefined) ->
    {Before, SleepMethod, LastSampleTime};

%% collected all samples, but CV is defined - check whether to collect more samples
measure_impl(Before, Handles, LastSampleTime, NextSampleTime, Interval, SleepMethod, 0, CV) ->
    %% Complication: some jobs may need a long time to stabilise compared to others.
    %% Decision: wait for all jobs to stabilise. Stopping completed jobs skews the measurements.
    case
        lists:any(
            fun (Samples) ->
                Normal = difference(Samples),
                Len = length(Normal),
                Mean = lists:sum(Normal) / Len,
                StdDev = math:sqrt(lists:sum([(S - Mean) * (S - Mean) || S <- Normal]) / (Len - 1)),
                StdDev / Mean > CV
            end, Before)
    of
        false ->
            {Before, SleepMethod, LastSampleTime};
        true ->
            %% imitate queue - drop last sample, push another in the head
            %% TODO: change the behaviour to return all samples in the full report
            TailLess = [lists:droplast(L) || L <- Before],
            measure_impl(TailLess, Handles, LastSampleTime, NextSampleTime + Interval,
                Interval, SleepMethod, 1, CV)
    end;

%% LastSampleTime: system time of the last sample
%% NextSampleTime: system time when to take the next sample
%% Interval: to calculate the next NextSampleTime
%% Count: how many more samples to take
%% CV: acceptable standard deviation
measure_impl(Before, Handles, LastSampleTime, NextSampleTime, Interval, SleepMethod, Count, CV) ->
    SleepFor = NextSampleTime - LastSampleTime,
    NextSleepMethod = sleep(SleepMethod, SleepFor, NextSampleTime),
    Counts = [erlperf_job:sample(Handle) || Handle <- Handles],
    NowTime = os:system_time(millisecond),
    measure_impl(merge(Counts, Before), Handles, NowTime, NextSampleTime + Interval, Interval,
        NextSleepMethod, Count - 1, CV).

%% ERTS real-time properties are easily broken by lock contention (e.g. ETS misuse)
%% When it happens, even the 'max' priority process may not run for an extended
%% period of time.
sleep(sleep, SleepFor, _WaitUntil) when SleepFor > 0 ->
    receive
        {'DOWN', _Ref, process, Pid, Reason} ->
            erlang:error({benchmark, {'EXIT', Pid, Reason}})
    after SleepFor ->
        sleep
    end;
sleep(_Mode, _SleepFor, WaitUntil) ->
    busy_wait(WaitUntil).

%% When sleep detects significant difference in the actual sleep time vs. expected,
%% loop is switched to the busy wait.
%% Once switched to busy wait, erlperf stays there until the end of the test.
busy_wait(WaitUntil) ->
    receive
        {'DOWN', _Ref, process, Pid, Reason} ->
            erlang:error({benchmark, {'EXIT', Pid, Reason}})
    after 0 ->
        case os:system_time(millisecond) of
            Now when Now > WaitUntil ->
                busy_wait;
            _ ->
                busy_wait(WaitUntil)
        end
    end.

merge([], []) ->
    [];
merge([M | T], [H | T2]) ->
    [[M | H] | merge(T, T2)].

difference([_]) ->
    [];
difference([S, F | Tail]) ->
    [F - S | difference([F | Tail])].

%% Determine maximum throughput by measuring multiple times with different concurrency.
%% Test considered complete when either:
%%  * maximum number of workers reached
%%  * last 'threshold' added workers did not increase throughput
estimate_concurrency(Jobs, Options, #{threshold := Threshold, max := Max} = ConOpts, Handles, Current, History, QMax) ->
    RunOptions = Options#{concurrency => Current},
    [Report] = benchmark_impl(Jobs, RunOptions, undefined, Handles),
    #{result := Result0} = Report,
    #{samples := Samples} = Result0,
    %% calculate average QPS
    QPS = lists:sum(difference(Samples)) div (length(Samples) - 1),
    Result = Result0#{average => QPS},
    NewHistory = [{Current, Result} | History],
    %% test if we are at Max concurrency, or saturated the node
    case maxed(QPS, Current, QMax, Threshold) of
        true ->
            %% QPS are either stable or decreasing, get back to the best run
            #{sleep := SleepMethod} = Report,
            {_BestMax, BestConcurrency} = QMax,
            {BestConcurrency, BestResult} = lists:keyfind(BestConcurrency, 1, History),
            #{mode => concurrency, result => BestResult, history => NewHistory, sleep => SleepMethod,
                concurrency_options => ConOpts, run_options => Options#{concurrency => BestConcurrency}};
        _NewQMax when Current =:= Max ->
            #{sleep := SleepMethod} = Report,
            #{mode => concurrency, result => Result, history => NewHistory, sleep => SleepMethod,
                concurrency_options => ConOpts, run_options => RunOptions};
        NewQMax ->
            % need more workers
            estimate_concurrency(Jobs, RunOptions, ConOpts, Handles, Current + 1, NewHistory, NewQMax)
    end.

maxed(QPS, Current, {Q, _}, _) when QPS > Q ->
    {QPS, Current};
maxed(_, Current, {_, W}, Count) when Current - W >= Count ->
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

%% Reporting: in full mode, add extra information (e.g. codes and statistics)
%% full report for continuous mode (needs history rewritten)
report(full, [Code], [#{mode := concurrency, history := History, result := Result, run_options := RunOpts} = Report]) ->
    System = system_report(),
    [Report#{system => System, code => Code,
        result => process_result(Result, continuous, RunOpts, #{}),
        history => [{C, process_result(R, continuous, #{report => full, concurrency => C}, #{})} || {C, R} <- History]}];
%% full reports
report(full, Codes, Reports) ->
    System = system_report(),
    [Report#{system => System, code => Code, result => process_result(Result, Mode, RunOptions, Report)}
        || {Code, #{mode := Mode, result := Result, run_options := RunOptions} = Report} <- lists:zip(Codes, Reports)];
report(_ReportType, _Codes, Reports) ->
    [process_result(Result, Mode, RunOptions, Report)
        || #{mode := Mode, result := Result, run_options := RunOptions} = Report <-Reports].

%% Transform raw samples into requested report
process_result(#{samples := Samples}, timed, #{report := full, samples := Count,
    sample_duration := {timed, Loop}}, _Report) ->
    Stat = report_stats(Samples),
    TotalTime = lists:sum(Samples),
    Stat#{time => TotalTime, iteration_time => TotalTime * 1000 div (Count * Loop), samples => Samples};
process_result(#{samples := Samples}, timed, #{report := basic}, _Report) ->
    %% timed mode, basic report
    lists:sum(Samples) div length(Samples) div 1000;
process_result(#{samples := Samples}, timed, #{report := extended}, _Report) ->
    %% timed mode, extended report, convert to milliseconds for backwards compatibility
    [S div 1000 || S <- Samples];
process_result(#{samples := Samples, time := TimeUs}, continuous, #{report := full, concurrency := C}, _Report) ->
    Stat = report_stats(difference(Samples)),
    IterationTime = case lists:last(Samples) - hd(Samples) of
                        0 ->
                            infinity;
                        Total ->
                            erlang:round(TimeUs * C * 1000 div Total)
                    end,
    Stat#{samples => Samples, time => TimeUs, iteration_time => IterationTime};
process_result(#{samples := Samples}, continuous, #{report := extended}, _Report) ->
    difference(Samples);
process_result(#{samples := Samples}, continuous, #{report := basic}, _Report) ->
    Diffs = difference(Samples),
    lists:sum(Diffs) div length(Diffs);
process_result(#{average := Avg}, concurrency, #{report := basic, concurrency := C}, _Report) ->
    {Avg, C};
process_result(#{average := Avg}, concurrency, #{report := extended, concurrency := C}, #{history := H}) ->
    %% return {Best, History}
    {{Avg, C}, [{A, W} || {W, #{average := A}} <- H]}.

%% @private
%% Calculates a requested statistical function over the passed samples.
%% Exported for unit-testing purposes
report_stats(Samples) ->
    Sum = lists:sum(Samples),
    Len = length(Samples),
    Avg = Sum / Len, %% arithmetic mean
    Variance = if Len =:= 0 -> 0; true -> lists:sum([(S - Avg) * (S - Avg) || S <- Samples]) / (Len - 1) end,
    Sorted = lists:sort(Samples),
    #{
        average => Avg,
        min => hd(Sorted),
        max => lists:last(Sorted),
        stddev => math:sqrt(Variance),
        median => lists:nth(erlang:round(0.50 * Len), Sorted),
        p99 => lists:nth(erlang:round(0.99 * Len), Sorted)
    }.

system_report() ->
    OSType = erlang:system_info(os_type),
    Guaranteed = #{
        os => OSType,
        system_version => string:trim(erlang:system_info(system_version), trailing)
    },
    try Guaranteed#{cpu => string:trim(detect_cpu(OSType), both)}
    catch _:_ -> Guaranteed
    end.

detect_cpu({unix, freebsd}) ->
    os:cmd("sysctl -n hw.model");
detect_cpu({unix, darwin}) ->
    os:cmd("sysctl -n machdep.cpu.brand_string");
detect_cpu({unix, linux}) ->
    {ok, Bin} = file:read_file("/proc/cpuinfo"),
    linux_cpu_model(binary:split(Bin, <<"\n">>));
detect_cpu({win32, nt}) ->
    [_, CPU] = string:split(os:cmd("WMIC CPU GET NAME"), "\n"),
    CPU.

linux_cpu_model([<<"model name", Model/binary>>, _]) ->
    [_, ModelName] = binary:split(Model, <<":">>),
    binary_to_list(ModelName);
linux_cpu_model([_Skip, Tail]) ->
    linux_cpu_model(binary:split(Tail, <<"\n">>)).