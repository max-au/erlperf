%%%-------------------------------------------------------------------
%%% @author Maxim Fedorov <maximfca@gmail.com>
%%% @copyright (C) 2019, Maxim Fedorov
%%% @doc
%%%   Benchmark/squeeze implementation, does not start any permanent
%%%     jobs.
%%% @end
-module(benchmark).
-author("maximfca@gmail.com").

%% Public API for single-run simple benchmarking
-export([
    run/1,
    run/2,
    run/3
]).

%% Permanent benchmarking API
-export([
]).

%% Single run options
-type run_options() :: #{
    % number of concurrently running workers (defaults to 1)
    % ignored when running concurrency test
    concurrency => pos_integer(),
    %% sampling interval: default is 1 second (to measure QPS)
    sample_duration => pos_integer(),
    %% warmup samples: first 'warmup' cycles are ignored (defaults to 0)
    warmup => pos_integer(),
    %% number of samples to take, defaults to 3
    samples => pos_integer(),
    %% coefficient of variation, when supplied, at least 'cycles'
    %%  samples must be within the specified coefficient
    %% experimental feature allowing to benchmark processes with
    %%  wildly jumping throughput
    cv => float(),
    %% report form for single benchmark: when set to 'extended',
    %%  all non-warmup samples are returned as a list.
    %% When missing, only the average QPS is returned.
    report => extended,
    %% this run requires a fresh BEAM that must be stopped to
    %%  clear up the mess
    isolation => node
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
    %% Minimum anx maximum number of workers to try
    min => pos_integer(),
    max => pos_integer()
}.

%% Single run result: one or multiple samples.
-type run_result() :: Throughput :: non_neg_integer() | [non_neg_integer()].

%% Concurrency test result:
-type concurrency_result() :: {QPS :: non_neg_integer(), Concurrency :: non_neg_integer()}.

%% Extended report returns all samples collected.
%% Basic report returns only maximum throughput achieved with
%%  amount of runners running at that time.
-type concurrency_test_result() :: concurrency_result() |
    {Max :: concurrency_result(), [concurrency_result()]}.

-export_type([run_options/0, concurrency_test/0]).

%% @doc Simple case.
%%  Runs a single benchmark for code(), and returns a steady QPS number.
-spec run(job:code()) -> non_neg_integer().
run(Code) ->
    run_impl(Code, #{}, undefined).

%% @doc
%% Single throughput measurement cycle.
%%  Job specification may include suite & worker init parts, suite cleanup,
%%  worker code, job name and identifier (id).
-spec run(job:code(), run_options()) -> run_result().
run(_Code, RunOptions) when is_map_key(init, RunOptions);
    is_map_key(init_runner, RunOptions); is_map_key(done, RunOptions) ->
    error("Hooks are passed together with code, in a map {Code, HooksMap}.");
run(Code, RunOptions) ->
    run_impl(Code, RunOptions, undefined).

%% @doc
%% Concurrency measurement run.
-spec run(job:code(), run_options(), concurrency_test()) ->
    concurrency_test_result().
run(_Code, RunOptions, _) when is_map_key(init, RunOptions);
    is_map_key(init_runner, RunOptions); is_map_key(done, RunOptions) ->
    error("Hooks are passed together with code, in a map {Code, HooksMap}.");
run(Code, RunOptions, ConTestOpts) ->
    run_impl(Code, RunOptions, ConTestOpts).

%%%===================================================================
%%% Implementation

run_impl(Code, Options, ConOpts) ->
    {ok, Pid} = job_sup:start_job(Code),
    try
        benchmark_impl(Pid, Options, ConOpts)
    after
        job_sup:stop_job(Pid)
    end.

-define(DEFAULT_SAMPLE_DURATION, 1000).

%% normal benchmark with concurrency specified
benchmark_impl(Pid, Options, ConOpts) ->
    {ok, CRef} = gen_server:call(Pid, get_counters), % hackety-hack,
    do_benchmark_impl(Pid, Options, ConOpts, CRef).

do_benchmark_impl(Pid, Options, undefined, CRef) ->
    Concurrency = maps:get(concurrency, Options, 1),
    ok = job:set_concurrency(Pid, Concurrency),
    perform_benchmark(CRef, Options);

do_benchmark_impl(Pid, Options, ConOpts, CRef) ->
    Min = maps:get(min, ConOpts, 1),
    perform_squeeze(Pid, CRef, Min, [], {0, 0}, Options,
        ConOpts#{max => maps:get(max, Options, erlang:system_info(process_limit) - 1000)}).

%% QPS considered stable when:
%%  * 'warmup' cycles have passed
%%  * 'cycles' cycles have been received
%%  * (optional) for the last 'cycles' cycles coefficient of variation did not exceed 'cv'
perform_benchmark(CRef, Options) ->
    Interval = maps:get(sample_duration, Options, ?DEFAULT_SAMPLE_DURATION),
    % skip 'warmup' cycles
    _ = [measure_impl(CRef, Interval) || _ <- lists:seq(1, maps:get(warmup, Options, 0))],
    % do at least 'cycles' cycles
    Samples = [measure_impl(CRef, Interval) || _ <- lists:seq(1, maps:get(samples, Options, 3))],
    verify_final(Samples, CRef, Interval, Options).

verify_final(Samples, CRef, Interval, #{cv := CV} = Options) ->
    Len = length(Samples),
    Mean = lists:sum(Samples) / Len,
    StdDev = math:sqrt(lists:sum([(S - Mean) * (S - Mean) || S <- Samples]) / (Len - 1)),
    if
        StdDev / Mean < CV ->
            report_benchmark(Samples, Options);
        true ->
            Sample = measure_impl(CRef, Interval),
            verify_final([Sample | lists:droplast(Samples)], CRef, Interval, Options)
    end,
    report_benchmark(Samples, Options);
verify_final(Samples, _, _, Options) ->
    report_benchmark(Samples, Options).

report_benchmark(Samples, #{report := extended}) ->
    Samples;
report_benchmark(Samples, _Options) ->
    lists:sum(Samples) div length(Samples).

measure_impl(CRef, Interval) ->
    Before = atomics:get(CRef, 1),
    timer:sleep(Interval),
    atomics:get(CRef, 1) - Before.

%% Determine maximum throughput by measuring multiple times with different concurrency.
%% Test considered complete when either:
%%  * maximum number of workers reached
%%  * last 'threshold' added workers did not increase throughput
perform_squeeze(_Pid, _CRef, Current, History, QMax, Options, #{max := Current}) ->
    % reached max allowed schedulers, exiting
    report_squeeze(QMax, History, Options);

perform_squeeze(Pid, CRef, Current, History, QMax, Options, ConOpts) ->
    ok = job:set_concurrency(Pid, Current),
    QPS = perform_benchmark(CRef, Options),
    %
    % ct:pal("QPS: ~b", [QPS]),
    %
    NewHistory = [{QPS, Current} | History],
    case maxed(QPS, Current, QMax, maps:get(threshold, ConOpts, 3))  of
        true ->
            % QPS are either stable or decreasing
            report_squeeze(QMax, NewHistory, Options);
        NewQMax ->
            % need more workers
            perform_squeeze(Pid, CRef, Current + 1, NewHistory, NewQMax, Options, ConOpts)
    end.

report_squeeze(QMax, History, Options) ->
    case maps:get(report, Options, undefined) of
        extended ->
            {QMax, History};
        _ ->
            QMax
    end.

maxed(QPS, Current, {Q, _}, _) when QPS > Q ->
    {QPS, Current};
maxed(_, Current, {_, W}, Count) when Current - W > Count ->
    true;
maxed(_, _, QMax, _) ->
    QMax.
