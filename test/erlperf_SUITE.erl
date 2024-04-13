%%%-------------------------------------------------------------------
%%% @author Maxim Fedorov <maximfca@gmail.com>
%%% @copyright (c) 2019-2023 Maxim Fedorov
%%% @doc
%%%     Tests benchmark module, machine-readable output for benchmarks.
%%% @end
%%% -------------------------------------------------------------------
-module(erlperf_SUITE).
-author("maximfca@gmail.com").

-include_lib("stdlib/include/assert.hrl").

-export([suite/0, all/0, groups/0, init_per_group/2, end_per_group/2]).

-export([
    start_link/0,
    init/1,
    handle_call/3,
    handle_cast/2
]).

%% Continuous mode benchmarks
-export([mfa/1, mfa_with_cv/1,
    mfa_with_tiny_cv/0, mfa_with_tiny_cv/1,
    mfa_concurrency/1, mfa_no_concurrency/1,
    code_extra_node/1, compare/1]).

%% Timed mode
-export([mfa_timed/1]).

%% Concurrency estimation tests
-export([mfa_squeeze/0, mfa_squeeze/1,
    squeeze_extended/0, squeeze_extended/1,
    squeeze_full/0, squeeze_full/1]).

%% Tests for error handling
-export([crasher/0, crasher/1, undefer/0, undefer/1, errors/0, errors/1]).

-export([lock_contention/0, lock_contention/1]).

-export([stat_calc/0, stat_calc/1, rand_stat/0, rand_stat/1]).

%% Record-replay tests
-export([replay/1, do_anything/1]).

-behaviour(gen_server).

%%--------------------------------------------------------------------
%% COMMON TEST CALLBACK FUNCTIONS

suite() ->
    [{timetrap, {seconds, 10}}].

groups() ->
    [
        {continuous, [parallel],
            [mfa, mfa_with_cv, mfa_with_tiny_cv, mfa_concurrency, mfa_no_concurrency, code_extra_node, compare]},
        {timed, [parallel],
            [mfa_timed]},
        {concurrency, [], [mfa_squeeze, squeeze_extended, squeeze_full]},
        {errors, [parallel], [crasher, undefer, errors]},
        {overhead, [], [lock_contention]},
        {statistics, [parallel], [stat_calc, rand_stat]},
        {replay, [], [replay]}
    ].

init_per_group(squeeze, Config) ->
    case erlang:system_info(schedulers_online) of
        LowCPU when LowCPU < 3 ->
            {skip, {slow_cpu, LowCPU}};
        _ ->
            Config
    end;
init_per_group(_, Config) ->
    Config.

end_per_group(_, Config) ->
    Config.

all() ->
    [{group, continuous}, {group, concurrency}, {group, overhead},
        {group, errors}, {group, statistics}, {group, replay}].

%%--------------------------------------------------------------------
%% Helpers: gen_server implementation
init(Pid) ->
    {ok, Pid}.

handle_call({sleep, Num}, _From, State) ->
    {reply, timer:sleep(Num), State}.

handle_cast(_Req, _State) ->
    erlang:error(notsup).

start_link() ->
    {ok, Pid} = gen_server:start_link(?MODULE, [], []),
    Pid.

%%--------------------------------------------------------------------
%% TEST CASES

mfa(Config) when is_list(Config) ->
    C = erlperf:run(timer, sleep, [1]),
    ?assert(C > 250 andalso C < 1101),
    %% extended report
    Extended = erlperf:run({timer, sleep, [1]}, #{report => extended, sample_duration => 100}),
    [?assert(Cs > 25 andalso Cs < 110) || Cs <- Extended],
    %% full report
    #{result := Result} = erlperf:run({timer, sleep, [1]}, #{report => full, sample_duration => 100}),
    #{average := Avg} = Result,
    ?assert(Avg > 25 andalso Avg < 110).

mfa_with_cv(Config) when is_list(Config) ->
    %% basic report
    C = erlperf:run({timer, sleep, [1]}, #{cv => 0.05}),
    ?assert(C > 250 andalso C < 1101).

mfa_with_tiny_cv() ->
    [{doc, "Tests benchmarking with very small coefficient of variation, potentially long"},
        {timetrap, {seconds, 60}}].

mfa_with_tiny_cv(Config) when is_list(Config) ->
    C = erlperf:run({timer, sleep, [1]}, #{samples => 2, interval => 100, cv => 0.002}),
    ?assert(C > 250 andalso C < 1101).

mfa_concurrency(Config) when is_list(Config) ->
    C = erlperf:run({timer, sleep, [1]}, #{concurrency => 2}),
    ?assert(C > 500 andalso C < 2202, {out_of_range, C, 500, 2202}).

compare(Config) when is_list(Config) ->
    [C1, C2] = erlperf:compare(["timer:sleep(1).", "timer:sleep(2)."],
        #{sample_duration => 100, report => extended}),
    ?assertEqual(3, length(C1), {not_extended, C1}),
    [?assert(L > R, {left, C1, right, C2}) || {L, R} <- lists:zip(C1, C2)],
    %% low-overhead comparison benchmark
    %% LEGACY/DEPRECATED: for timed mode, extended report has only 1 sample
    [[T1], [T2]] = erlperf:benchmark([#{runner => {timer, sleep, [1]}}, #{runner => "timer:sleep(2)."}],
        #{sample_duration => undefined, samples => 50, report => extended}, undefined),
    ?assert(is_integer(T1) andalso is_integer(T2)),
    ?assert(T1 < T2, {T1, T2}).

mfa_no_concurrency(Config) when is_list(Config) ->
    C = erlperf:run(
        #{
            runner => fun (Pid) -> gen_server:call(Pid, {sleep, 1}) end,
            init => {?MODULE, start_link, []},
            init_runner => fun(Pid) -> Pid end,
            done => {gen_server, stop, []}
        },
        #{concurrency => 4}),
    ?assert(C > 250 andalso C < 1101, {out_of_range, C, 250, 1101}).

code_extra_node(Config) when is_list(Config) ->
    C = erlperf:run(#{
            runner => "{ok, 1} = application:get_env(kernel, test), timer:sleep(1).",
            init => "application:set_env(kernel, test, 1)."
        },
        #{concurrency => 2, sample_duration => 100, isolation => #{}}),
    ?assertEqual(undefined, application:get_env(kernel, test), {"isolation did not work"}),
    ?assert(C > 50 andalso C < 220, {out_of_range, C, 50, 220}).

%%--------------------------------------------------------------------
%% timed mode

mfa_timed(Config) when is_list(Config) ->
    %% basic report for 100 'timer:sleep(1) iterations'
    Time = erlperf:time({timer, sleep, [1]}, 100),
    ?assert(Time > 100 andalso Time < 300, {actual, Time}), %% between 100 and 300 ms
    %% extended report for 50 iterations
    Times = erlperf:run({timer, sleep, [1]}, #{samples => 5, report => extended, sample_duration => {timed, 50}}),
    ?assertEqual(5, length(Times), {times, Times}),
    [?assert(T > 50 andalso T < 150, {actual, T}) || T <- Times], %% every run between 50 and 150 ms.
    %% full report for 50 iterations
    Full = erlperf:run({timer, sleep, [1]}, #{samples => 5, report => full, sample_duration => {timed, 50}}),
    #{result := #{average := Avg, samples := FullSsamples}} = Full,
    ?assertEqual(5, length(FullSsamples)),
    ?assert(Avg > 50000.0 andalso Avg < 150000.0, {actual, Avg}), %% average run between 50 and 150 us (!us!)
    %% ensure 'warmup' is supported for timed runs
    Now = os:system_time(millisecond),
    Warmup = erlperf:run({timer, sleep, [1]}, #{samples => 5, warmup => 10, sample_duration => {timed, 50}}),
    ?assert(Warmup > 50 andalso Warmup < 150, {actual, Warmup}), %% between 50 and 150 ms
    Elapsed = os:system_time(millisecond) - Now,
    ?assert(Elapsed > 750, {warmup_missing, Elapsed}),
    ?assert(Elapsed < 3000, {warmup_slow, Elapsed}).

%%--------------------------------------------------------------------
%% concurrency estimation test cases

mfa_squeeze() ->
    [{doc, "Tests concurrency estimation mode with basic report"}].

mfa_squeeze(Config) when is_list(Config) ->
    Scheds = erlang:system_info(schedulers_online),
    {QPS, CPU} = erlperf:run({rand, uniform, [1]}, #{sample_duration => 50}, #{}),
    ?assert(QPS > 0),
    ?assert(CPU > 1, {schedulers, Scheds, detected, CPU}).

squeeze_extended() ->
    [{doc, "Tests concurrency estimation mode with extended report"}].

squeeze_extended(Config) when is_list(Config) ->
    {{QPS, CPU}, History} = erlperf:run({rand, uniform, [1]},
        #{sample_duration => 50, warmup => 1, report => extended}, #{}),
    %% find the best historical result, and ensure it's 3 steps away from the last
    [Best | _] = lists:reverse(lists:keysort(1, History)),
    ?assertEqual({QPS, CPU}, Best),
    ?assertEqual(Best, lists:nth(4, History), History).

squeeze_full() ->
    [{doc, "Tests concurrency estimation mode with full report"}].

squeeze_full(Config) when is_list(Config) ->
    Report = erlperf:run({rand, uniform, [1]}, #{sample_duration => 50, warmup => 1, report => full}, #{}),
    #{mode := concurrency, result := Best, history := History, sleep := sleep,
        run_options := #{concurrency := Concurrency}} = Report,
    #{time := Time} = Best,
    ct:pal("Best run took ~b ms,~n~p", [Time div 1000, Best]),
    %% taking 3 samples
    ?assert(Time >= 3 * 50000, {too_fast, Time}),
    ?assert(Time < 3 * 100000, {too_slow, Time}),
    ?assertEqual({Concurrency, Best}, lists:nth(4, History)).

%%--------------------------------------------------------------------
%% error handling test cases

crasher() ->
    [{doc, "Tests job that crashes"}].

crasher(Config) when is_list(Config) ->
    ?assertException(error, {benchmark, {'EXIT', _, _}},
        erlperf:run({erlang, throw, [ball]}, #{concurrency => 2})).

undefer() ->
    [{doc, "Tests job undefs - e.g. wrong module name"}].

undefer(Config) when is_list(Config) ->
    ?assertException(error, {benchmark, {'EXIT', _, {undef, _}}},
        erlperf:run({'$cannot_be_this', throw, []}, #{concurrency => 2})).

errors() ->
    [{doc, "Tests various error conditions"}].

errors(Config) when is_list(Config) ->
    ?assertException(error, {generate, {parse, init, _}},
        erlperf:run(#{runner => {erlang, node, []}, init => []})),
    ?assertException(error, {generate, {parse, runner, _}},
        erlperf:run(#{runner => []})),
    ?assertException(error, {generate, {parse, runner, _}},
        erlperf:run(#{runner => {[]}})).

%%--------------------------------------------------------------------
%% timer skew detection

lock_contention() ->
    [{doc, "Ensures that benchmarking overhead when running multiple concurrent processes is not too high"},
        {timetrap, {seconds, 20}}].

lock_contention(Config) when is_list(Config) ->
    %% need at the very least 4 schedulers to create enough contention
    case erlang:system_info(schedulers_online) of
        Enough when Enough >= 4 ->
            Tuple = {lists:seq(1, 5000), list_to_tuple(lists:seq(1, 10000))},
            Init = fun() -> ets:new(tab, [public, named_table]) end,
            Done = fun(Tab) -> ets:delete(Tab) end,
            Runner = fun() -> true = ets:insert(tab, Tuple) end, %% this inevitably causes lock contention
            %% take 50 samples of 10 ms, which should complete in about a second, and 10 extra warmup samples
            %% hoping that lock contention is detected at warmup
            Before = os:system_time(millisecond),
            Report = erlperf:run(#{runner => Runner, init => Init, done => Done},
                #{concurrency => Enough * 4, samples => 50, sample_duration => 10, warmup => 10, report => full}),
            TimeSpent = os:system_time(millisecond) - Before,
            #{result := #{average := QPS}, sleep := DetectedSleepType} = Report,
            ?assertEqual(busy_wait, DetectedSleepType, {"Lock contention was not detected", Report}),
            ?assert(QPS > 0, {qps, QPS}),
            ?assert(TimeSpent > 500, {too_quick, TimeSpent, expected, 1000}),
            ?assert(TimeSpent < 3000, {too_slow, TimeSpent, expected, 1000});
        NotEnough ->
            {skip, {not_enough_schedulers_online, NotEnough}}
    end.

%%--------------------------------------------------------------------
%% statistics

%% simplified delta-comparison
-define(assertApprox(Expect, Expr),
    begin
        ((fun () ->
            X__X = (Expect),
            X__Y = (Expr),
            case (erlang:abs(X__Y - X__X) < 0.0001) of
                true -> ok;
                false -> erlang:error({assertEqual,
                    [{module, ?MODULE},
                        {line, ?LINE},
                        {expression, (??Expr)},
                        {expected, X__X},
                        {value, X__Y}]})
            end
          end)())
    end).

stat_calc() ->
    [{doc, "Tests correctness of statistical calculations over samples"}].

stat_calc(Config) when is_list(Config) ->
    %% generate with: [erlang:round(rand:normal(40, 100)) || _ <- lists:seq(1, 30)].
    Sample = [36,42,42,47,51,39,37,32,41,32,15,44,41,46,50,36,48,33,35,
        35,25,21,47,40,33,57,55,64,40,30],

    Stats = erlperf:report_stats(Sample),

    ?assertApprox(39.8, maps:get(average, Stats)),
    %% ?assertApprox(109.0620, maps:get(variance, Stats)),
    ?assertApprox(10.4432, maps:get(stddev, Stats)),
    ?assertEqual(40, maps:get(median, Stats)),
    ?assertEqual(15, maps:get(min, Stats)),
    ?assertEqual(64, maps:get(max, Stats)),
    %% ?assertApprox(47, maps:get({percentile, 0.75}, Stats)),
    ?assertApprox(64, maps:get(p99, Stats)).

rand_stat() ->
    [{doc, "Use rand module to generate some wildly random results"}].

rand_stat(Config) when is_list(Config) ->
    Report = erlperf:run({rand, uniform, []}, #{report => full, samples => 100, sample_duration => 5}),
    #{result := Result, mode := continuous, system := System} = Report,
    #{min := Min, max := Max, average := Avg, median := Mid, p99 := P99} = Result,
    %% just run some sanity checks assertions
    ?assertEqual(erlang:system_info(os_type), maps:get(os, System)),
    ?assert(is_map_key(cpu, System), {cpu_missing, System}),
    ?assert(Min < Max, {min, Min, max, Max}),
    ?assert(Avg > Min andalso Avg < Max, {avg, Avg, min, Min, max, Max}),
    ?assert(Mid > Min andalso Mid < Max, {median, Mid, min, Min, max, Max}),
    ?assert(P99 =< Max, {p99, P99, max, Max}).

%%--------------------------------------------------------------------
%% record-replay

replay(Config) when is_list(Config) ->
    spawn(fun () -> timer:sleep(10), do_anything(10) end),
    Trace = erlperf:record(?MODULE, '_', '_', 100),
    QPS = erlperf:run(Trace),
    ?assert(QPS > 10).

do_anything(0) ->
    timer:sleep(1);
do_anything(N) ->
    ?MODULE:do_anything(N - 1).