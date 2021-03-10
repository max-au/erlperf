%#!/usr/bin/env escript

%%%-------------------------------------------------------------------
%%% @author Maxim Fedorov <maximfca@gmail.com>
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
    compare/2,
    record/4,
    start/2,
    load/1,
    profile/2
]).

%% Public API: escript
-export([
    main/1
]).

%% Formatters & convenience functions.
-export([
    format/3,
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

%% Profile options
-type profile_options() :: #{
    profiler => fprof,
    format => term | binary | string
}.

-export_type([isolation/0, run_options/0, concurrency_test/0]).

%% Milliseconds, timeout for any remote node operation
-define(REMOTE_NODE_TIMEOUT, 10000).

%% @doc Simple case.
%%  Runs a single benchmark, and returns a steady QPS number.
%%  Job specification may include suite &amp; worker init parts, suite cleanup,
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
%% Records call trace, so it could be used to benchmark later.
-spec record(module(), atom(), non_neg_integer(), pos_integer()) ->
    [[{module(), atom(), [term()]}]].
record(Module, Function, Arity, TimeMs) ->
    TracerPid = spawn_link(fun tracer/0),
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
%% Starts a continuously running job in a new BEAM instance.
-spec start(ep_job:code(), isolation()) -> {ok, node(), pid()}.
start(Code, _Isolation) ->
    [Node] = prepare_nodes(1),
    {ok, Pid} = rpc:call(Node, ep_job, start, [Code], ?REMOTE_NODE_TIMEOUT),
    {ok, Node, Pid}.

%% @doc
%% Loads previously saved job (from file in the priv_dir)
-spec load(file:filename()) -> ep_job:code().
load(Filename) ->
    {ok, Bin} = file:read_file(filename:join(code:priv_dir(erlperf), Filename)),
    binary_to_term(Bin).

%% @doc
%% Runs a profiler for specified code
-spec profile(ep_job:code(), profile_options()) -> binary() | string() | [term()].
profile(Code, Options) ->
    {ok, Job} = ep_job:start_link(Code),
    Profiler = maps:get(profiler, Options, fprof),
    Format = maps:get(format, Options, string),
    Result = ep_job:profile(Job, Profiler, Format),
    ep_job:stop(Job),
    Result.

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
    Prog = #{progname => "erlperf"},
    try
        erlang:process_flag(trap_exit, true),
        RunOpts = argparse:parse(Args, arguments(), Prog),
        Code0 = [parse_code(C) || C <- maps:get(code, RunOpts)],
        {_, Code} = lists:foldl(fun callable/2, {RunOpts, Code0}, [init, init_runner, done]),
        COpts = case maps:find(squeeze, RunOpts) of
                    {ok, true} ->
                        maps:with([min, max, threshold], RunOpts);
                    error ->
                        #{}
                end,
        ROpts = maps:with([concurrency, samples, sample_duration, cv, isolation, warmup, verbose, profile],
            RunOpts),
        main_impl(ROpts, COpts, Code)
    catch
        error:{argparse, Reason} ->
            Fmt = argparse:format_error(Reason, arguments(), Prog),
            io:format("error: ~s", [Fmt]);
        error:{badmatch, {error, {{parse, Reason}, _}}} ->
            format(error, "parse error: ~s~n", [Reason]);
        error:{badmatch, {error, {{compile, Reason}, _}}} ->
            format(error, "compile error: ~s~n", [Reason]);
        error:{badmatch, {error, {Reason, Stack}}} ->
            format(error, "error starting job: ~ts~n~p~n", [Reason, Stack]);
        Cls:Rsn:Stack ->
            format(error, "Unhandled exception: ~ts:~p~n~p~n", [Cls, Rsn, Stack])
    end.

callable(Type, {Args, Acc}) ->
    {Args, merge_callable(Type, maps:get(Type, Args, []), Acc, [])}.

merge_callable(_Type, [], Acc, Merged) ->
    lists:reverse(Merged) ++ Acc;
merge_callable(_Type, _, [], Merged) ->
    lists:reverse(Merged);
merge_callable(Type, [[H] | T], [HA | Acc], Merged) ->
    merge_callable(Type, T, Acc, [HA#{Type => H} | Merged]).

parse_code(Code) ->
    case lists:last(Code) of
        $. ->
            #{runner => Code};
        $} when hd(Code) =:= ${ ->
            % parse MFA tuple with added "."
            #{runner => parse_mfa_tuple(Code)};
        _ ->
            case file:read_file(Code) of
                {ok, Bin} ->
                    #{runner => parse_call_record(Bin)};
                Other ->
                    error({"Unable to read file with call recording\n" ++
                        "Did you forget to end your function with period? (dot)",
                        Code, Other})
            end
    end.

parse_mfa_tuple(Code) ->
    {ok, Scan, _} = erl_scan:string(Code ++ "."),
    {ok, Term} = erl_parse:parse_term(Scan),
    Term.

parse_call_record(Bin) ->
    binary_to_term(Bin).

arguments() ->
    #{help =>
    "erlperf 'timer:sleep(1).'\n"
    "erlperf 'rand:uniform().' 'crypto:strong_rand_bytes(2).' --samples 10 --warmup 1\n"
    "erlperf 'pg2:create(foo).' --squeeze\n"
    "erlperf 'pg2:join(foo, self()), pg2:leave(foo, self()).' --init 1 'pg2:create(foo).' --done 1 'pg2:delete(foo).'\n",
        arguments => [
            #{name => concurrency, short => $c, long => "-concurrency",
                help => "number of concurrently executed runner processes",
                default => 1, type => {int, [{min, 1}, {max, 1024 * 1024 * 1024}]}},
            #{name => sample_duration, short => $d, long => "-duration",
                help => "single sample duration", default => 1000,
                type => {int, [{min, 1}]}},
            #{name => samples, short => $s, long => "-samples",
                help => "minimum number of samples to collect", default => 3,
                type => {int, [{min, 1}]}},
            #{name => warmup, short => $w, long => "-warmup",
                help => "number of samples to skip", default => 0,
                type => {int, [{min, 0}]}},
            #{name => cv, long => "-cv",
                help => "coefficient of variation",
                type => {float, [{min, 0.0}]}},
            #{name => verbose, short => $v, long => "-verbose",
                type => boolean, help => "verbose output"},
            #{name => profile, long => "-profile", type => boolean,
                help => "run fprof profiler for the supplied code"},
            #{name => isolated, short => $i, long => "-isolated", type => boolean,
                action => count, help => "run benchmarks in isolated environment (slave node)"},
            #{name => squeeze, short => $q, long => "-squeeze", type => boolean,
                action => count, help => "run concurrency test"},
            #{name => min, long => "-min",
                help => "start with this amount of processes", default => 1,
                type => {int, [{min, 1}]}},
            #{name => max, long => "-max",
                help => "do not exceed this number of processes",
                type => {int, [{max, 1024 * 1024 * 1024}]}},
            #{name => threshold, short => $t, long => "-threshold",
                help => "cv at least <threshold> samples should be less than <cv> to increase concurrency", default => 3,
                type => {int, [{min, 1}]}},
            #{name => init, long => "-init",
                help => "init code", nargs => 1, action => append},
            #{name => done, long => "-done",
                help => "done code", nargs => 1, action => append},
            #{name => init_runner, long => "-init_runner",
                help => "init_runner code", nargs => 1, action => append},
            #{name => code,
                help => "code to test", nargs => nonempty_list, action => extend}
        ]}.

%%-------------------------------------------------------------------
%% Color output

-spec format(error | warining, string(), [term()]) -> ok.
format(Level, Format, Terms) ->
    io:format(color(Level, Format), Terms).

-define(RED, "\e[31m").
-define(MAGENTA, "\e[35m").
-define(END, "\e[0m~n").

color(error, Text) -> ?RED ++ Text ++ ?END;
color(warning, Text) -> ?MAGENTA ++ Text ++ ?END;
color(_, Text) -> Text.


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

% wrong usage
main_impl(_RunOpts, SqueezeOps, [_, _ | _]) when map_size(SqueezeOps) > 0 ->
    io:format("Multiple concurrency tests is not supported, run it one by one~n");

main_impl(RunOpts, SqueezeOpts, Codes) ->
    NeedLogger = maps:get(verbose, RunOpts, false),
    application:set_env(erlperf, start_monitor, NeedLogger),
    ok = logger:set_handler_config(default, level, warning),
    NeedToStop =
        case application:start(erlperf) of
            ok ->
                true;
            {error, {already_started,erlperf}} ->
                false
        end,
    % verbose?
    Logger =
        if NeedLogger ->
            {ok, Pid} = ep_file_log:start(group_leader()),
                Pid;
            true ->
                undefined
        end,
    try
        run_main(RunOpts, SqueezeOpts, Codes)
    after
        Logger =/= undefined andalso ep_file_log:stop(Logger),
        NeedToStop andalso application:stop(erlperf)
    end.

% profile
run_main(#{profile := true}, _, [Code]) ->
    Profile = erlperf:profile(Code, #{profiler => fprof, format => string}),
    io:format("~s~n", [Profile]);

% squeeze test
% Code                         Concurrency   Throughput
% pg2:create(foo).                      14      9540 Ki
run_main(RunOpts, SqueezeOps, [Code]) when map_size(SqueezeOps) > 0 ->
    {QPS, Con} = run(Code, RunOpts, SqueezeOps),
    #{runner := CodeRunner} = Code,
    MaxCodeLen = min(code_length(CodeRunner), 62),
    io:format("~*s     ||        QPS~n", [-MaxCodeLen, "Code"]),
    io:format("~*s ~6b ~10s~n", [-MaxCodeLen, format_code(CodeRunner), Con, format_number(QPS)]);

% benchmark
% erlperf 'timer:sleep(1).'
% Code               Concurrency   Throughput
% timer:sleep(1).              1          498
% --
% Code                         Concurrency   Throughput   Relative
% rand:uniform().                        1      4303 Ki       100%
% crypto:strong_rand_bytes(2).           1      1485 Ki        35%

run_main(RunOpts, _, Codes0) ->
    Results = run_impl(Codes0, RunOpts, undefined),
    MaxQPS = lists:max(Results),
    Concurrency = maps:get(concurrency, RunOpts, 1),
    Codes = [maps:get(runner, Code) || Code <- Codes0],
    MaxCodeLen = min(lists:max([code_length(Code) || Code <- Codes]) + 4, 62),
    io:format("~*s     ||        QPS     Rel~n", [-MaxCodeLen, "Code"]),
    Zipped = lists:reverse(lists:keysort(2, lists:zip(Codes, Results))),
    [io:format("~*s ~6b ~10s ~6b%~n", [-MaxCodeLen, format_code(Code),
        Concurrency, format_number(QPS), QPS * 100 div MaxQPS]) ||
        {Code, QPS}  <- Zipped].

format_code(Code) when is_tuple(Code) ->
    lists:flatten(io_lib:format("~tp", [Code]));
format_code(Code) when is_tuple(hd(Code)) ->
    lists:flatten(io_lib:format("[~tp, ...]", [hd(Code)]));
format_code(Code) ->
    Code.

code_length(Code) ->
    length(format_code(Code)).

%%%===================================================================
%%% Benchmarking itself

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

prepare_nodes(HowMany) ->
    not erlang:is_alive() andalso error(not_alive),
    % start multiple nodes, ensure cluster_monitor is here (start supervisor if needs to)
    [_, HostString] = string:split(atom_to_list(node()), "@"),
    Host = list_to_atom(HostString),
    Nodes = start_nodes(lists:duplicate(HowMany, Host), []),
    % start 'erlperf' app on all slaves
    Expected = lists:duplicate(HowMany, {ok, [erlperf]}),
    %
    case rpc:multicall(Nodes, application, ensure_all_started, [erlperf], ?REMOTE_NODE_TIMEOUT) of
        {Expected, []} ->
            Nodes;
        Other ->
            error({start_failed, Other, Expected, Nodes})
    end.

%% isolation requested: need to rely on cluster_monitor and other distributed things.
run_impl(Codes, #{isolation := _Isolation} = Options, ConOpts) ->
    Nodes = prepare_nodes(length(Codes)),
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
    report_benchmark(Samples, maps:get(report, Options, false)).

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
report_benchmark(SamplesList, false) ->
    [lists:sum(Samples) div length(Samples) || Samples <- SamplesList].

%% Determine maximum throughput by measuring multiple times with different concurrency.
%% Test considered complete when either:
%%  * maximum number of workers reached
%%  * last 'threshold' added workers did not increase throughput
perform_squeeze(_Pid, _CRef, Current, History, QMax, Options, #{max := Max}) when Current > Max ->
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

%%%===================================================================
%%% Tracer process, uses heap to store tracing information.
tracer() ->
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
