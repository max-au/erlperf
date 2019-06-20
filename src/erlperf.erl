%#!/usr/bin/env escript

%%%-------------------------------------------------------------------
%%% @author Maxim Fedorov <maximfca@gmail.com>
%%% @copyright (C) 2019, Maxim Fedorov
%%% @doc
%%%   Benchmark/squeeze implementation, does not start any permanent
%%%     jobs.
%%%   Command line interface.
%%% @end
-module(erlperf).
-author("maximfca@gmail.com").

%% Public API for single-run simple benchmarking
%% Programmatic access.
-export([
    run/1,
    run/2,
    run/3,
    compare/2
]).

%% Public API: escript
-export([
    main/1,
    run_impl/3
]).

%% Formatters & convenience functions.
-export([
    start/0,
    format_number/1,
    format_size/1
]).

%% node isolation options:
-type isolation() :: #{
    host => string()
}.

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

%% @doc Simple case.
%%  Runs a single benchmark, and returns a steady QPS number.
%%  Job specification may include suite & worker init parts, suite cleanup,
%%  worker code, job name and identifier (id).
-spec run(ep_job:code()) -> non_neg_integer().
run(Code) ->
    [Series] = run_impl([Code], #{}, undefined),
    Series.

%% @doc
%% Single throughput measurement cycle.
%% Additional options are applied.
-spec run(ep_job:code(), run_options()) -> run_result().
run(Code, RunOptions) ->
    [Series] = run_impl([Code], RunOptions, undefined),
    Series.

%% @doc
%% Concurrency measurement run.
-spec run(ep_job:code(), run_options(), concurrency_test()) ->
    concurrency_test_result().
run(Code, RunOptions, ConTestOpts) ->
    [Series] = run_impl([Code], RunOptions, ConTestOpts),
    Series.

%% @doc
%% Comparison run: starts several jobs and measures throughput for
%%  all of them at the same time.
%% All job options are honoured, and if there is isolation applied,
%%  every job runs its own node.
-spec compare([ep_job:code()], run_options()) -> [run_result()].
compare(Codes, RunOptions) ->
    run_impl(Codes, RunOptions, undefined).

%% @doc Simple command-line benchmarking interface.
%% Example: erlperf 'rand:uniform().'
-spec main([string()]) -> no_return().
main(Args) ->
    {RunOpts, ConcurrencyOpts, Code} =  parse_cmd_line(Args, {#{}, #{}, []}),
    main_impl(RunOpts, ConcurrencyOpts, Code).

%% @doc
%% Starts erlperf as an Erlang/OTP application.
start() ->
    application:start(erlperf).

%% @doc Formats number rounded to 3 digits.
%%  Example: 88 -> 88, 880000 -> 880 Ki, 100501 -> 101 Ki
-spec format_number(non_neg_integer()) -> string().
format_number(Num) when Num > 100000000000 ->
    integer_to_list(round(Num / 1000000000)) ++ " Gi";
format_number(Num) when Num > 100000000 ->
    integer_to_list(round(Num / 1000000)) ++ " Mi";
format_number(Num) when Num > 100000 ->
    integer_to_list(round(Num / 1000)) ++ " Ki";
format_number(Num) ->
    integer_to_list(Num).

%% @doc Formats size (bytes) rounded to 3 digits.
%%  Unlinke @see format_number, used 1024 as a base,
%%  so 200 * 1024 is 200 Kb.
-spec format_size(non_neg_integer()) -> string().
format_size(Num) when Num > 1024*1024*1024 * 100 ->
    integer_to_list(round(Num / (1024*1024*1024))) ++ " Gb";
format_size(Num) when Num > 1024*1024*100 ->
    integer_to_list(round(Num / (1024 * 1024))) ++ " Mb";
format_size(Num) when Num > 1024 * 100 ->
    integer_to_list(round(Num / 1024)) ++ " Kb";
format_size(Num) ->
    integer_to_list(Num).

%%%===================================================================
%%% Command line implementation
%%% ArgParse library is not ready yet, so do home-made parsing

parse_cmd_line([], {RunOpt, COpt, Codes}) ->
    {RunOpt, COpt, lists:reverse(Codes)};
% run options
parse_cmd_line([Opt, Number | Tail], {RunOpt, COpt, Codes}) when Opt =:= "--concurrency"; Opt =:= "-c" ->
    parse_cmd_line(Tail, {RunOpt#{concurrency => list_to_integer(Number)}, COpt, Codes});
parse_cmd_line([Opt, Number | Tail], {RunOpt, COpt, Codes}) when Opt =:= "--sample_duration"; Opt =:= "-d"  ->
    parse_cmd_line(Tail, {RunOpt#{sample_duration => list_to_integer(Number)}, COpt, Codes});
parse_cmd_line([Opt, Number | Tail], {RunOpt, COpt, Codes}) when Opt =:= "--warmup"; Opt =:= "-w"  ->
    parse_cmd_line(Tail, {RunOpt#{warmup => list_to_integer(Number)}, COpt, Codes});
parse_cmd_line([Opt, Number | Tail], {RunOpt, COpt, Codes}) when Opt =:= "--samples"; Opt =:= "-s"  ->
    parse_cmd_line(Tail, {RunOpt#{samples => list_to_integer(Number)}, COpt, Codes});
parse_cmd_line([Opt, Number | Tail], {RunOpt, COpt, Codes}) when Opt =:= "--cv" ->
    parse_cmd_line(Tail, {RunOpt#{cv => list_to_float(Number)}, COpt, Codes});
parse_cmd_line([Opt | Tail], {RunOpt, COpt, Codes}) when Opt =:= "--isolated"; Opt =:= "-i" ->
    parse_cmd_line(Tail, {RunOpt#{isolation => node}, COpt, Codes});
% squeeze options
parse_cmd_line([Opt, Number | Tail], {RunOpt, COpt, Codes}) when Opt =:= "--min" ->
    parse_cmd_line(Tail, {RunOpt, COpt#{min => list_to_integer(Number)}, Codes});
parse_cmd_line([Opt, Number | Tail], {RunOpt, COpt, Codes}) when Opt =:= "--max" ->
    parse_cmd_line(Tail, {RunOpt, COpt#{max => list_to_integer(Number)}, Codes});
parse_cmd_line([Opt, Number | Tail], {RunOpt, COpt, Codes}) when Opt =:= "--threshold"; Opt =:= "-t" ->
    parse_cmd_line(Tail, {RunOpt, COpt#{threshold => list_to_integer(Number)}, Codes});
parse_cmd_line([Opt | Tail], {RunOpt, COpt, Codes}) when Opt =:= "--squeeze"; Opt =:= "-q"  ->
    parse_cmd_line(Tail, {RunOpt, COpt#{run => true}, Codes}); % this adds a key to map, making it non-empty
parse_cmd_line([Opt | Tail], {RunOpt, COpt, Codes}) when Opt =:= "--verbose"; Opt =:= "-v"  ->
    parse_cmd_line(Tail, {RunOpt#{verbose => true}, COpt, Codes});
% invalid options
parse_cmd_line([[$- | Opt] | _Tail], _) ->
    io:format("Unrecognised option: ~s~n", [Opt]),
    {#{}, #{}, []};
% must be code
parse_cmd_line([Code | Tail], {RunOpt, COpt, Codes}) ->
    parse_cmd_line(Tail, {RunOpt, COpt, [Code | Codes]}).

main_impl(_, _, []) ->
    io:format("Usage: erlperf [OPTIONS] CODE1 [CODE2]~n"),
    io:format("Options: ~n"),
    io:format("    -c, --concurrency  PROCS    - number of concurrencly execured runner processes (default 1)~n"),
    io:format("    -d, --duration     MILLISEC - single sample duration (default 1000)~n"),
    io:format("    -s, --samples      SAMPLES  - minimum number of samples to collect (default 3)~n"),
    io:format("    -w, --warmup       SAMPLES  - number of samples to skip (default 0)~n"),
    io:format("    --cv               FLOAT    - coefficient of variation (not used by default)~n"),
    io:format("    -v, --verbose               - additional output printed~n"),
    io:format("    -i, --isolated              - run benchmarks in isolated environment (slave node)~n"),
    io:format("Concurrency measurement options: ~n"),
    io:format("    -q, --squeeze               - run concurrency test~n"),
    io:format("    --min              PROCS    - start with this amount of processes (default 1)~n"),
    io:format("    --max              PROCS    - stop squueze test after reaching this value~n"),
    io:format("    -t, --threshold    SAMPLES  - collect more samples for squeeze test (default 3)~n"),
    io:format("Code examples: ~n"),
    io:format("    rand:uniform(123).~n"),
    io:format("    runner() -> timer:sleep(1).~n"),
    io:format("    runner(Arg) -> Count = rand:uniform(Arg), [pg2:join(foo) ||_ <- lists:seq(1, Count)].~n");

% wrong usage
main_impl(_RunOpts, SqueezeOps, [_, _ | _]) when map_size(SqueezeOps) > 0 ->
    io:format("Multiple concurrency tests is not supported, run it one by one~n");

main_impl(RunOpts, SqueezeOpts, Codes) ->
    application:set_env(erlperf, start_monitor, false),
    NeedToStop =
        case application:start(erlperf) of
            ok ->
                true;
            {error, {already_started,erlperf}} ->
                false
        end,
    try
        run_main(RunOpts, SqueezeOpts, Codes)
    after
        NeedToStop andalso application:stop(erlperf)
    end.

% squeeze test
% Code                         Concurrency   Throughput
% pg2:create(foo).                      14      9540 Ki
run_main(RunOpts, SqueezeOps, [Code]) when map_size(SqueezeOps) > 0 ->
    {QPS, Con} = run(Code, RunOpts, SqueezeOps),
    MaxCodeLen = min(length(Code), 62),
    io:format("~*s     ||        QPS~n", [-MaxCodeLen, "Code"]),
    io:format("~*s ~6b ~10s~n", [-MaxCodeLen, Code, Con, format_number(QPS)]);

% benchmark
% erlperf 'timer:sleep(1).'
% Code               Concurrency   Throughput
% timer:sleep(1).              1          498
% --
% Code                         Concurrency   Throughput   Relative
% rand:uniform().                        1      4303 Ki       100%
% crypto:strong_rand_bytes(2).           1      1485 Ki        35%

run_main(RunOpts, _, Codes) ->
    Results = run_impl(Codes, RunOpts, undefined),
    MaxQPS = lists:max(Results),
    Concurrency = maps:get(concurrency, RunOpts, 1),
    MaxCodeLen = min(lists:max([length(Code) || Code <- Codes]) + 4, 62),
    io:format("~*s     ||        QPS     Rel~n", [-MaxCodeLen, "Code"]),
    Zipped = lists:reverse(lists:keysort(2, lists:zip(Codes, Results))),
    [io:format("~*s ~6b ~10s ~6b%~n", [-MaxCodeLen, Code, Concurrency, format_number(QPS), QPS * 100 div MaxQPS]) ||
        {Code, QPS}  <- Zipped].

%%%===================================================================
%%% Benchmarking itself

%% Milliseconds, timeout for any remote node operation
-define(REMOTE_NODE_TIMEOUT, 10000).

start_nodes([], Nodes) ->
    Nodes;
start_nodes([Host | Tail], Nodes) ->
    NodeId = list_to_atom("job_" ++ integer_to_list(rand:uniform(65536))),
    % TODO: use real erl_prim_loader inet with hosts equal to this host
    Path = filename:dirname(code:where_is_file("erlperf.app")),
    case slave:start_link(Host, NodeId, "-pa " ++ Path ++ " -setcookie " ++ atom_to_list(erlang:get_cookie())) of
        {ok, Node} ->
            start_nodes(Tail, [Node | Nodes]);
        {error, {already_running, _}} ->
            start_nodes([Host | Tail], Nodes)
    end.

%% isolation requested: need to rely on cluster_monitor and other distributed things.
run_impl(Codes, #{isolation := _Isolation} = Options, ConOpts) ->
    not erlang:is_alive() andalso error(not_alive),
    % start multiple nodes, ensure cluster_monitor is here (start supervisor if needs to)
    [_, HostString] = string:split(atom_to_list(node()), "@"),
    Host = list_to_atom(HostString),
    Nodes = start_nodes(lists:duplicate(length(Codes), Host), []),
    % start 'erlperf' app on all slaves
    Expected = lists:duplicate(length(Codes), {ok, [erlperf]}),
    %
    case rpc:multicall(Nodes, application, ensure_all_started, [erlperf], ?REMOTE_NODE_TIMEOUT) of
        {Expected, []} ->
            ok;
        Other ->
            error({start_failed, Other, Expected, Nodes})
    end,
    % start jobs on these nodes, this isn't a multi-call though, but a pmap.
    Opts = maps:remove(isolation, Options),
    try
        % no timeout here (except that rpc itself could time out)
        Promises =
            [rpc:async_call(Node, erlperf, run, [Code, Opts, ConOpts])
                || {Node, Code} <- lists:zip(Nodes, Codes)],
        % now wait for everyone to respond
        lists:reverse(lists:foldl(fun (Key, Acc) -> [rpc:yield(Key) | Acc] end, [], Promises))
    after
        [slave:stop(Node) || Node <- Nodes]
    end;

%% no isolation requested, do normal in-BEAM test
run_impl(Codes, Options, ConOpts) ->
    Jobs = [begin {ok, Pid} = ep_job:start(Code), Pid end || Code <- Codes],
    try
        benchmark_impl(Jobs, Options, ConOpts)
    after
        [ep_job:stop(Job) || Job <- Jobs]
    end.

-define(DEFAULT_SAMPLE_DURATION, 1000).

benchmark_impl(Jobs, Options, ConOpts) ->
    CRefs = [ep_job:get_counters(Job) || Job <- Jobs],
    do_benchmark_impl(Jobs, Options, ConOpts, CRefs).

%% normal benchmark
do_benchmark_impl(Jobs, Options, undefined, CRefs) ->
    Concurrency = maps:get(concurrency, Options, 1),
    [ok = ep_job:set_concurrency(Job, Concurrency) || Job <- Jobs],
    perform_benchmark(CRefs, Options);

%% squeeze test - concurrency benchmark
do_benchmark_impl(Jobs, Options, ConOpts, CRef) ->
    Min = maps:get(min, ConOpts, 1),
    perform_squeeze(Jobs, CRef, Min, [], {0, 0}, Options,
        ConOpts#{max => maps:get(max, ConOpts, erlang:system_info(process_limit) - 1000)}).

%% QPS considered stable when:
%%  * 'warmup' cycles have passed
%%  * 'cycles' cycles have been received
%%  * (optional) for the last 'cycles' cycles coefficient of variation did not exceed 'cv'
perform_benchmark(CRefs, Options) ->
    Interval = maps:get(sample_duration, Options, ?DEFAULT_SAMPLE_DURATION),
    % sleep for "warmup * sample_duration"
    timer:sleep(Interval * maps:get(warmup, Options, 0)),
    % do at least 'cycles' cycles
    Before = [[atomics:get(CRef, 1)] || CRef <- CRefs],
    Samples = measure_impl(Before, CRefs, Interval, maps:get(samples, Options, 3), maps:get(cv, Options, undefined)),
    report_benchmark(Samples, maps:find(report, Options)).

measure_impl(Before, _CRefs, _Interval, 0, undefined) ->
    normalise(Before);

measure_impl(Before, CRefs, Interval, 0, CV) ->
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
            measure_impl(TailLess, CRefs, Interval, 1, CV)
    end;

measure_impl(Before, CRefs, Interval, Count, CV) ->
    timer:sleep(Interval),
    Counts = [atomics:get(CRef, 1) || CRef <- CRefs],
    measure_impl(merge(Counts, Before), CRefs, Interval, Count - 1, CV).

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
report_benchmark(SamplesList, _) ->
    [lists:sum(Samples) div length(Samples) || Samples <- SamplesList].

%% Determine maximum throughput by measuring multiple times with different concurrency.
%% Test considered complete when either:
%%  * maximum number of workers reached
%%  * last 'threshold' added workers did not increase throughput
perform_squeeze(_Pid, _CRef, Current, History, QMax, Options, #{max := Current}) ->
    % reached max allowed schedulers, exiting
    report_squeeze(QMax, History, Options);

perform_squeeze(Jobs, CRef, Current, History, QMax, Options, ConOpts) ->
    ok = ep_job:set_concurrency(hd(Jobs), Current),
    [QPS] = perform_benchmark(CRef, Options),
    NewHistory = [{QPS, Current} | History],
    case maxed(QPS, Current, QMax, maps:get(threshold, ConOpts, 3))  of
        true ->
            % QPS are either stable or decreasing
            report_squeeze(QMax, NewHistory, Options);
        NewQMax ->
            % need more workers
            perform_squeeze(Jobs, CRef, Current + 1, NewHistory, NewQMax, Options, ConOpts)
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
