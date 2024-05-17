%%%-------------------------------------------------------------------
%%% @author Maxim Fedorov <maximfca@gmail.com>
%%% @copyright (c) 2019-2023 Maxim Fedorov
%%% -------------------------------------------------------------------
-module(erlperf_cli_SUITE).
-author("maximfca@gmail.com").

-include_lib("stdlib/include/assert.hrl").

-export([suite/0, all/0]).

-export([
    simple/1, concurrent/1, verbose/1, zero/1, compare/1,
    usage/1, init/1,
    double/1, triple/1, pg/1, mfa/1,
    full_report/1, basic_timed_report/1, full_timed_report/1,
    recorded/1,
    squeeze/0, squeeze/1, step/1,
    init_all/0, init_all/1
]).

%%--------------------------------------------------------------------
%% COMMON TEST CALLBACK FUNCTIONS

suite() ->
    [{timetrap, {seconds, 20}}].

all() ->
    [simple, concurrent, verbose, zero, compare, squeeze, step, usage, init, double,
        triple, pg, mfa, full_report, basic_timed_report, full_timed_report, recorded, init_all].

%%--------------------------------------------------------------------
%% helper functions
capture_io(Fun) ->
    ok = ct:capture_start(),
    Fun(),
    ok = ct:capture_stop(),
    lists:flatten(ct:capture_get()).

%%--------------------------------------------------------------------
%% command-line testing

parse_qps(QPST, "") -> list_to_integer(QPST);
parse_qps(QPST, "Ki") -> list_to_integer(QPST) * 1000;
parse_qps(QPST, "Mi") -> list_to_integer(QPST) * 1000000;
parse_qps(QPST, "Gi") -> list_to_integer(QPST) * 1000000000;
parse_qps(QPST, "Ti") -> list_to_integer(QPST) * 1000000000000.

parse_duration(TT, "ns") -> list_to_integer(TT);
parse_duration(TT, "us") -> list_to_integer(TT) * 1000;
parse_duration(TT, "ms") -> list_to_integer(TT) * 1000000;
parse_duration(TT, "s") -> list_to_integer(TT) * 1000000000;
parse_duration(TT, "m") -> list_to_integer(TT) * 60 * 1000000000.

filtersplit(Str, Sep) ->
    [L || L <- string:split(Str, Sep, all), L =/= ""].

parse_out(Out) ->
    [Header | Lines] = filtersplit(Out, "\n"),
    case filtersplit(Header, " ") of
        ["Code", "||", "QPS", "Time"] ->
            [begin
                 case filtersplit(Ln, " ") of
                     [Code, ConcT, QPST, TT, TTU] ->
                         {Code, list_to_integer(ConcT), parse_qps(QPST, ""), parse_duration(TT, TTU)};
                     [Code, ConcT, QPST, QU, TT, TTU] ->
                         {Code, list_to_integer(ConcT), parse_qps(QPST, QU), parse_duration(TT, TTU)}
                 end
             end || Ln <- Lines];
        ["Code", "||", "QPS", "Time", "Rel"] ->
            [begin
                 case filtersplit(Ln, " ") of
                     [Code, ConcT, "0", "inf", Rel] ->
                         {Code, list_to_integer(ConcT), 0, infinity,
                             list_to_integer(lists:droplast(Rel))};
                     [Code, ConcT, QPST, TT, TTU, Rel] ->
                         {Code, list_to_integer(ConcT), parse_qps(QPST, ""), parse_duration(TT, TTU),
                             list_to_integer(lists:droplast(Rel))};
                     [Code, ConcT, QPST, QU, TT, TTU, Rel] ->
                         {Code, list_to_integer(ConcT), parse_qps(QPST, QU), parse_duration(TT, TTU),
                             list_to_integer(lists:droplast(Rel))}
                 end
             end || Ln <- Lines];
        ["Code", "||", "Samples", "Avg", "StdDev", "Median", "P99", "Iteration" | Rel] ->
            [begin
                 [Code, ConcT, Samples, Avg0 | T1] = filtersplit(Ln, " "),
                 {Avg, T2} = maybe_unit(Avg0, T1),
                 [StdDevPercent, Median0 | T3] = T2,
                 {Median, T4} = maybe_unit(Median0, T3),
                 [P990 | T5] = T4,
                 {P99, [TT, TU | T6]} = maybe_unit(P990, T5),
                 ?assertEqual($%, lists:last(StdDevPercent)),
                 StdDev = list_to_float(lists:droplast(StdDevPercent)),
                 Returned = [Code, list_to_integer(ConcT), list_to_integer(Samples), Avg,
                     StdDev, Median, P99, parse_duration(TT, TU)],
                 case Rel of
                     [] ->
                         list_to_tuple(Returned);
                     ["Rel"] ->
                         ?assertEqual($%, lists:last(T6)),
                         Relative = list_to_integer(lists:droplast(T6)),
                         list_to_tuple(Returned ++ [Relative])
                 end
             end || Ln <- Lines];
        Unparsed ->
            ct:pal("Unkonwn header: ~p", [Unparsed]),
            ?assert(false)
    end.

maybe_unit(Num, [[U, $i] | Tail]) ->
    {parse_qps(Num, [U, $i]), Tail};
maybe_unit(Num, [TimeUnit | Tail]) when TimeUnit =:= "m"; TimeUnit =:= "s"; TimeUnit =:= "ms"; TimeUnit =:= "ns"; TimeUnit =:= "us"  ->
    {parse_duration(Num, TimeUnit), Tail};
maybe_unit(Num, Rem) ->
    {list_to_integer(Num), Rem}.

%%--------------------------------------------------------------------
%% TEST CASES

% erlperf 'timer:sleep(1). -d 100'
simple(Config) when is_list(Config) ->
    Code = "timer:sleep(1).",
    Out = capture_io(fun() -> erlperf_cli:main([Code, "-d", "100"]) end),
    [{Code, 1, C, T}] = parse_out(Out),
    ?assert(C > 25 andalso C < 110, {qps, C}),
    ?assert(T > 1000000 andalso T < 3000000, {time, T}).

concurrent(Config) when is_list(Config) ->
    Code = "timer:sleep(1).",
    Out = capture_io(fun() -> erlperf_cli:main([Code, "-d", "100", "-c", "8"]) end),
    [{Code, 8, C, T}] = parse_out(Out),
    ?assert(C > 8 * 25 andalso C < 8 * 110, {qps, C}),
    ?assert(T > 1000000 andalso T < 3000000, {time, T}).

% erlperf 'timer:sleep(1). -v'
verbose(Config) when is_list(Config) ->
    Code = "timer:sleep(1).",
    Out = capture_io(fun () -> erlperf_cli:main([Code, "-v"]) end),
    Lines = filtersplit(Out, "\n"),
    %% TODO: actually verify that stuff printed is monitoring stuff
    ?assert(length(Lines) > 3),
    %% expect first 5 lines to contain source code
    Generated = lists:sublist(Lines, 1, 12),
    ?assertEqual(Generated, [
        ">>>>>>>>>>>>>>> timer:sleep(1).                  ",
        "-module(benchmark).",
        "-export([benchmark/0, benchmark_finite/1]).","benchmark() ->",
        "    timer:sleep(1),","    benchmark().",
        "benchmark_finite(0) ->","    ok;","benchmark_finite(Count) ->",
        "    timer:sleep(1),","    benchmark_finite(Count - 1).",
        "<<<<<<<<<<<<<<< "]),
    %% parse last 2 lines
    [{Code, 1, C, T}] = parse_out(lists:join("\n", lists:sublist(Lines, length(Lines) - 1, 2))),
    ?assert(C > 250 andalso C < 1101, {qps, C}),
    ?assert(T > 1000000 andalso T < 3000000, {time, T}).

% erlperf 'timer:sleep(100).' 'timer:sleep(200).' -d 10
zero(Config) when is_list(Config) ->
    Out = capture_io(fun () -> erlperf_cli:main(["timer:sleep(100).", "timer:sleep(200).", "-d", "10"]) end),
    % Code            Concurrency   Throughput      Time      Rel
    % timer:sleep(200).          1          0        inf       0%
    % timer:sleep(100).          1          0        inf       0%
    [{_Code, 1, 0, infinity, 0}, {_Code2, 1, 0, infinity, 0}] = parse_out(Out).

% erlperf 'timer:sleep(1).' 'timer:sleep(2).' -d 100 -s 5 -w 1 -c 2
compare(Config) when is_list(Config) ->
    Out = capture_io(
        fun () -> erlperf_cli:main(["timer:sleep(1).", "timer:sleep(2).", "-s", "5", "-d", "100", "-w", "1", "-c", "2"]) end),
    % Code            Concurrency   Throughput      Time      Rel
    % timer:sleep().            2          950    100 ns     100%
    % timer:sleep(2).           2          475    200 ns      50%
    [{_Code, 2, C, T, R}, {_Code2, 2, C2, T2, R2}] = parse_out(Out),
    ?assert(C > 66 andalso C < 220, {qps, C}),
    ?assert(C2 > 50 andalso C2 < 110, {qps, C2}),
    ?assert(T < T2),
    ?assert(R > R2).

squeeze() ->
    [{doc, "Tests concurrency test via command line"}, {timetrap, {seconds, 30}}].

% erlperf 'timer:sleep(1).' --duration 50 --squeeze --min 2 --max 4 --threshold 2
squeeze(Config) when is_list(Config) ->
    Out = capture_io(
        fun () -> erlperf_cli:main(["timer:sleep(1).", "--duration", "50", "--squeeze", "--min", "2", "--max", "4", "--threshold", "2"]) end),
    [{_Code, 4, C, T}] = parse_out(Out),
    ?assert(C > 50 andalso C < 220, {qps, C}),
    ?assert(T > 1000000 andalso T < 3000000, {time, T}).

% erlperf 'timer:sleep(1).' --duration 50 --squeeze --min 1 --max 25 --step 10
step(Config) when is_list(Config) ->
    Out = capture_io(
        fun () -> erlperf_cli:main(["timer:sleep(1).", "--duration", "50", "--squeeze", "--min", "1", "--max", "25", "--step", "10"]) end),
    [{_Code, 20, C, T}] = parse_out(Out),
    ?assert(C > 400 andalso C < 600, {qps, C}),
    ?assert(T > 1000000 andalso T < 3000000, {time, T}).
% erlperf -q
usage(Config) when is_list(Config) ->
    Out = capture_io(fun () -> erlperf_cli:main(["-q"]) end),
    Line1 = "Error: erlperf: required argument missing: code",
    ?assertEqual(Line1, lists:sublist(Out, length(Line1))),
    Out2 = capture_io(fun () -> erlperf_cli:main(["--un code"]) end),
    ?assertEqual("Error: erlperf: unrecognised argument: --un code", lists:sublist(Out2, 48)),
    ok.

% erlperf '{file,_}=code:is_loaded(pool).' --init 'code:ensure_loaded(pool).' --done 'code:purge(pool), code:delete(pool).'
init(Config) when is_list(Config) ->
    Code = "{file,_}=code:is_loaded(pool).",
    Out = capture_io(fun () -> erlperf_cli:main(
        [Code, "--init", "code:ensure_loaded(pool).", "--done", "code:purge(pool), code:delete(pool)."])
                                  end),
    % verify 'done' was done
    ?assertEqual(false, code:is_loaded(pool)),
    % verify output
    [{_Code, 1, C, T}] = parse_out(Out),
    ?assert(C > 50, {qps, C}),
    ?assert(T > 0, {time, T}).

% erlperf 'runner(X) -> timer:sleep(X).' --init '1.' 'runner(Y) -> timer:sleep(Y).' --init '2.' -s 2 --duration 100
double(Config) when is_list(Config) ->
    Code = "runner(X)->timer:sleep(X).",
    Out = capture_io(fun () -> erlperf_cli:main([Code, "--init_runner", "1.", Code, "--init_runner", "2.", "-s", "2",
        "--duration", "100"]) end),
    [{Code, 1, C, T, R}, {Code, 1, C2, T2, R2}] = parse_out(Out),
    ?assert(C > 25 andalso C < 110, {qps, C}),
    ?assert(C2 > 25 andalso C2 < 55, {qps, C2}),
    ?assert(T < T2),
    ?assert(R > R2).

triple(Config) when is_list(Config) ->
    Out = capture_io(fun () -> erlperf_cli:main(["timer:sleep(1).", "-s", "2", "--duration", "100",
        "timer:sleep(2).", "timer:sleep(3)."]) end),
    [_, _, {_, 1, C3, _T3, R3}] = parse_out(Out),
    ?assert(C3 >= 20 andalso C3 =< 30, {"expected between 20 and 30, got", C3}),
    ?assert(R3 >= 40 andalso R3 =< 60, {"expected between 40 and 60, got", R3}),
    ok.

% erlperf 'runner(Arg) -> ok = pg:join(Arg, self()), ok = pg:leave(Arg, self()).' --init_runner 'pg:create(self()), self().'
pg(Config) when is_list(Config) ->
    ?assertEqual(undefined, whereis(scope)), %% ensure scope is not left
    Code = "runner(S)->pg:join(S,g,self()),pg:leave(S,g,self()).",
    Out = capture_io(fun () -> erlperf_cli:main(
        [Code, "--init_runner", "{ok,Scope}=pg:start_link(scope),Scope."])
                                  end),
    ?assertEqual(undefined, whereis(scope)), %% ensure runner exited
    [{_Code, 1, C, _T}] = parse_out(Out),
    ?assert(C > 100, {qps, C}).

% erlperf '{rand, uniform, [4]}'
mfa(Config) when is_list(Config) ->
    Code = "{rand,uniform,[4]}",
    Out = capture_io(fun () -> erlperf_cli:main([Code]) end),
    [{Code, 1, _C, _T}] = parse_out(Out).

% erlperf 'timer:sleep(1). -d 100 -r full'
full_report(Config) when is_list(Config) ->
    Code = "timer:sleep(1).",
    AllOut = capture_io(fun () -> erlperf_cli:main([Code, "-d", "100", "-r", "full"]) end),
    [[$O, $S | _], A1] = string:split(AllOut, "\n"), %% test that first string is OS
    [[$C, $P, $U | _], A2] = string:split(A1, "\n"),
    [[$V, $M, $ , $:, $ | VM], A3] = string:split(A2, "\n"), %% extract VM
    [_, Out] = string:split(A3, "\n"),
    ?assertEqual(string:trim(erlang:system_info(system_version)), string:trim(VM, both)),
    [{Code, 1, Samples, Avg, Dev, Med, P99, Time}] = parse_out(Out),
    ?assertEqual(3, Samples),
    ?assert(Med =< P99),
    ?assert(Dev < 50, {deviation, Dev}),
    ?assert(Avg > 25 andalso Avg < 110, {avg, Avg}),
    ?assert(Time > 1000000 andalso Time < 3000000, {time, Time}).

% erlperf 'timer:sleep(1).' -r basic -s 3 -l 50
basic_timed_report(Config) when is_list(Config) ->
    Code = "timer:sleep(1).",
    Out = capture_io(fun () -> erlperf_cli:main([Code, "-r", "basic", "-s", "3", "-l", "50"]) end),
    [{_Code, 1, QPS, IterTime}] = parse_out(Out),
    ct:pal("Basic Timed Report:~n~p", [Out]),
    ?assert(QPS > 250 andalso QPS < 1100, {qps, QPS}), %% QPS of 'timer:sleep(1)' is ~500
    ?assert(IterTime >= 1000000 andalso IterTime < 3000000, {time, IterTime}). %% single iteration of timer:sleep(1)

% erlperf 'timer:sleep(1).' -r full -l 100 -s 5
full_timed_report(Config) when is_list(Config) ->
    Code = "timer:sleep(1).",
    AllOut = capture_io(fun () -> erlperf_cli:main([Code, "-r", "full", "-l", "100", "-s", "5"]) end),
    ct:pal("Full Timed Report:~n~p", [AllOut]),
    [[$O, $S | _], A1] = string:split(AllOut, "\n"), %% test that first string is OS
    [[$C, $P, $U | _], A2] = string:split(A1, "\n"),
    [[$V, $M, $ , $:, $ | VM], A3] = string:split(A2, "\n"), %% extract VM
    [_, Out] = string:split(A3, "\n"),
    ?assertEqual(string:trim(erlang:system_info(system_version)), string:trim(VM, both)),
    [{Code, 1, Samples, Avg, Dev, Med, P99, Time}] = parse_out(Out),
    ?assertEqual(5, Samples),
    ?assert(Med =< P99),
    ?assert(Dev < 50, {deviation, Dev}),
    ?assert(Avg >= 200000000 andalso Avg < 400000000, {avg, Avg}), %% average time to complete 100 iterations of sleep(1)
    ?assert(Time >= 1000000 andalso Time < 3000000, {time, Time}). %% single timer:sleep(1) time, in us


% erlperf 'runner(Arg) -> ok = pg2:join(Arg, self()), ok = pg2:leave(Arg, self()).' --init 'ets:file2tab("pg2.tab").'
recorded(Config) ->
    % write down ETS table to file
    Priv = proplists:get_value(priv_dir, Config),
    EtsFile = filename:join(Priv, "ets.tab"),
    RecFile = filename:join(Priv, "recorded.list"),
    test_ets_tab = ets:new(test_ets_tab, [named_table, public, ordered_set]),
    [true = ets:insert(test_ets_tab, {N, rand:uniform(100)}) || N <- lists:seq(1, 100)],
    ok = ets:tab2file(test_ets_tab, EtsFile),
    true = ets:delete(test_ets_tab),
    %
    ok = file:write_file(RecFile, term_to_binary(
        [
            {ets, insert, [test_ets_tab, {100, 40}]},
            {ets, delete, [test_ets_tab, 100]}
        ])),
    %
    Out = capture_io(fun () -> erlperf_cli:main(
        [RecFile, "--init", "ets:file2tab(\"" ++ EtsFile ++ "\")."])
                                  end),
    [LN1, LN2] = string:split(Out, "\n"),
    ?assertEqual(["Code", "||", "QPS", "Time"], string:lexemes(LN1, " ")),
    ?assertMatch(["[{ets,insert,[test_ets_tab,{100,40}]},", "...]", "1" | _], string:lexemes(LN2, " ")),
    ok.

init_all() ->
    [{doc, "Test init_all, done_all, init_runner_all options "}].

%% ./erlperf 'runner(X)->timer:sleep(X).' 'runner(X)->timer:sleep(X).' 'runner(X)->timer:sleep(X).'
%%      --init_all '5.' --init '1.' --init_runner_all 'ir(Z) -> Z * 2.' --init_runner '5.' --init_runner '2.' --done_all '2.'
init_all(Config) when is_list(Config) ->
    Code = "runner(X)->timer:sleep(X).",
    Code2 = "runner(Y)->timer:sleep(Y).",
    %% how this test works:
    %%  --init_all returns 5 for all 3 tests, for code#1 --init is overridden to be 1.
    %%  --init_runner_all returns 2x of init result, but there is override for #1 and #2 returning 5 and 2
    %%  resulting delays are 5, 2 and 10.
    Out = capture_io(fun () -> erlperf_cli:main(
        [Code, Code2, Code, "--init_all", "5.", "--init", "1.", "--init_runner_all", "ir(Z) -> Z * 2.",
            "--init_runner", "5.", "--init_runner", "2.",
            "--done_all", "2.", "-s", "2", "--duration", "100"]) end), %% unrelated parts to make the test quicker
    [{Code2, 1, C1, _, R}, {Code, 1, C2, _, R2}, {Code, 1, C3, _, R3}] = parse_out(Out),
    %% tests sorting as well
    ?assert(C1 > 25 andalso C1 < 55, {qps, C1}), %% 2 ms delay
    ?assert(C2 > 10 andalso C2 < 25, {qps, C2}), %% 5 ms delay
    ?assert(C3 > 5 andalso C3 < 11, {qps, C3}), %% 10 ms delay
    ?assert(R > R2), %% 5 ms delay is less than 2 ms
    ?assert(R2 > R3). %% 5 ms delay is more than 10 ms
