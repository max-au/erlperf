%%%-------------------------------------------------------------------
%%% @author Maxim Fedorov <maximfca@gmail.com>
%%% @copyright (c) 2019-2022 Maxim Fedorov
%%% @doc
%%%     Tests benchmark module, machine-readable output for benchmarks.
%%% @end
%%% -------------------------------------------------------------------
-module(erlperf_SUITE).
-author("maximfca@gmail.com").

-include_lib("stdlib/include/assert.hrl").

-export([suite/0, all/0, groups/0]).

-export([
    start_link/0,
    init/1,
    handle_call/3,
    handle_cast/2
]).

-export([mfa/1, mfa_with_cv/1,
    mfa_with_tiny_cv/0, mfa_with_tiny_cv/1,
    mfa_list/1, mfa_fun/1, mfa_fun1/1, code/1,
    code_fun/1, code_fun1/1, mfa_init/1, mfa_fun_init/1,
    code_gen_server/1, mfa_concurrency/1, mfa_no_concurrency/1,
    code_extra_node/1, mixed/0, mixed/1,
    crasher/0, crasher/1, undefer/0, undefer/1, compare/1,
    errors/0, errors/1]).

-export([
    cmd_line_simple/1, cmd_line_verbose/1, cmd_line_compare/1,
    cmd_line_squeeze/1, cmd_line_usage/1, cmd_line_init/1,
    cmd_line_double/1, cmd_line_triple/1, cmd_line_pg/1, cmd_line_mfa/1,
    cmd_line_recorded/1,
    cmd_line_squeeze/0
]).

-export([mfa_squeeze/0, mfa_squeeze/1, replay/1, do_anything/1]).

-behaviour(gen_server).

%%--------------------------------------------------------------------
%% COMMON TEST CALLBACK FUNCTIONS

suite() ->
    [{timetrap, {seconds, 10}}].

groups() ->
    [
        {benchmark, [parallel], [
            mfa,
            mfa_with_cv,
            mfa_with_tiny_cv,
            mfa_list,
            mfa_fun,
            mfa_fun1,
            code,
            code_fun,
            code_fun1,
            mfa_init,
            mfa_fun_init,
            code_gen_server,
            mfa_concurrency,
            mfa_no_concurrency,
            code_extra_node,
            mixed,
            crasher, undefer,
            compare,
            errors
        ]},
        {cmdline, [sequential], [
            cmd_line_simple,
            cmd_line_verbose,
            cmd_line_compare,
            cmd_line_squeeze,
            cmd_line_usage,
            cmd_line_init,
            cmd_line_double,
            cmd_line_triple,
            cmd_line_pg,
            cmd_line_mfa,
            cmd_line_recorded
        ]},
        {squeeze, [], [
            mfa_squeeze
        ]},
        {replay, [sequential], [
            replay
        ]}
    ].

all() ->
    [{group, benchmark}, {group, cmdline}, {group, squeeze}, {group, replay}].

%%--------------------------------------------------------------------
%% Helpers: gen_server implementation
init(Pid) ->
    {ok, Pid}.

handle_call({sleep, Num}, _From, State) ->
    timer:sleep(Num),
    {reply, ok, State}.

handle_cast(_Req, _State) ->
    erlang:error(notsup).

start_link() ->
    {ok, Pid} = gen_server:start_link(?MODULE, [], []),
    Pid.

%%--------------------------------------------------------------------
%% helper functions
capture_io(Fun) ->
    ok = ct:capture_start(),
    Fun(),
    ok = ct:capture_stop(),
    lists:flatten(ct:capture_get()).

%%--------------------------------------------------------------------
%% TEST CASES
%% Permutations:
%% Config permutations:
%%  -init
%%  -done
%%  -init_worker
%%  -concurrency
%%  -samples
%%  -warmup
%%  -interval

mfa(Config) when is_list(Config) ->
    C = erlperf:run(timer, sleep, [1]),
    ?assert(C > 250 andalso C < 1101),
    Time = erlperf:time({timer, sleep, [1]}, 100),
    ?assert(Time > 100000 andalso Time < 300000). %% between 100 and 300 ms

mfa_with_cv(Config) when is_list(Config) ->
    C = erlperf:run({timer, sleep, [1]}, #{cv => 0.05}),
    ?assert(C > 250 andalso C < 1101).

mfa_with_tiny_cv() ->
    [{doc, "Tests benchmarking with very small coefficient of variation, potentially long"},
        {timetrap, {seconds, 60}}].

mfa_with_tiny_cv(Config) when is_list(Config) ->
    C = erlperf:run({timer, sleep, [1]}, #{samples => 2, interval => 100, cv => 0.002}),
    ?assert(C > 250 andalso C < 1101).

mfa_list(Config) when is_list(Config) ->
    C = erlperf:run([{rand, seed, [exrop]}, {timer, sleep, [1]}, {rand, uniform, [20]}, {timer, sleep, [1]}]),
    ?assert(C > 200 andalso C < 450, {out_of_range, C, 200, 450}).

mfa_fun(Config) when is_list(Config) ->
    C = erlperf:run(fun () -> timer:sleep(1) end),
    ?assert(C > 250 andalso C < 1101, {out_of_range, C, 250, 1101}).

mfa_fun1(Config) when is_list(Config) ->
    C = erlperf:run(#{runner => fun (undefined) -> timer:sleep(1); (ok) -> timer:sleep(1) end,
        init_runner => fun() -> undefined end}),
    ?assert(C > 250 andalso C < 1101, {out_of_range, C, 250, 1101}).

code(Config) when is_list(Config) ->
    C = erlperf:run("timer:sleep(1)."),
    ?assert(C > 250 andalso C < 1101, {out_of_range, C, 250, 1101}).

code_fun(Config) when is_list(Config) ->
    C = erlperf:run("runner() -> timer:sleep(1)."),
    ?assert(C > 250 andalso C < 1101, {out_of_range, C, 250, 1101}).

code_fun1(Config) when is_list(Config) ->
    C = erlperf:run(#{runner => "runner(undefined) -> timer:sleep(1), undefined.",
        init_runner => "undefined."}),
    ?assert(C > 250 andalso C < 1101, {out_of_range, C, 250, 1101}).

mfa_init(Config) when is_list(Config) ->
    C = erlperf:run(#{
        runner => fun (1) -> timer:sleep(1) end,
        init => [{rand, seed, [exrop]}, {rand, uniform, [100]}],
        init_runner => {erlang, abs, [-1]}
    }),
    ?assert(C > 250 andalso C < 1101, {out_of_range, C, 250, 1101}).

mfa_fun_init(Config) when is_list(Config) ->
    C = erlperf:run(#{
        runner => fun(Timeout) -> timer:sleep(Timeout) end,
        init => fun () -> ok end,
        init_runner => fun (ok) -> 1 end
    }),
    ?assert(C > 250 andalso C < 1101, {out_of_range, C, 250, 1101}).

code_gen_server(Config) when is_list(Config) ->
    C = erlperf:run(#{
        runner => "run(Pid) -> gen_server:call(Pid, {sleep, 1}).",
        init => "Pid = " ++ atom_to_list(?MODULE) ++ ":start_link(), register(server, Pid), Pid.",
        init_runner => "local(Pid) when is_pid(Pid) -> Pid.",
        done => "stop(Pid) -> gen_server:stop(Pid)."
    }),
    ?assertEqual(undefined, whereis(server)),
    ?assert(C > 250 andalso C < 1101, {out_of_range, C, 250, 1101}).

mfa_concurrency(Config) when is_list(Config) ->
    C = erlperf:run({timer, sleep, [1]}, #{concurrency => 2}),
    ?assert(C > 500 andalso C < 2202, {out_of_range, C, 500, 2202}).

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
    ?assertEqual(undefined, application:get_env(kernel, test)),
    ct:pal("~p", [C]),
    ?assert(C > 50 andalso C < 220, {out_of_range, C, 50, 220}).

crasher() ->
    [{doc, "Tests job that crashes"}].

crasher(Config) when is_list(Config) ->
    ?assertException(error, {benchmark, {'EXIT', _, _}},
        erlperf:run({erlang, throw, [ball]}, #{concurrency => 2})).

mixed() ->
    [{doc, "Tests mixed approach when code co-exists with MFAs"}].

mixed(Config) when is_list(Config) ->
    C = erlperf:run(#{
        runner => [{timer, sleep, [1]}, {timer, sleep, [2]}],
        init => "rand:uniform().",
        init_runner => fun (Int) -> Int end
    }),
    ?assert(C > 100 andalso C < 335, {out_of_range, C, 100, 335}).

undefer() ->
    [{doc, "Tests job undefs - e.g. wrong module name"}].

undefer(Config) when is_list(Config) ->
    ?assertException(error, {benchmark, {'EXIT', _, {undef, _}}},
        erlperf:run({'$cannot_be_this', throw, []}, #{concurrency => 2})).

compare(Config) when is_list(Config) ->
    [C1, C2] = erlperf:compare(["timer:sleep(1).", "timer:sleep(2)."], #{sample_duration => 100}),
    ?assert(C1 > C2),
    %% low-overhead comparison benchmark
    [T1, T2] = erlperf:benchmark([#{runner => {timer, sleep, [1]}}, #{runner => "timer:sleep(2)."}],
        #{sample_duration => undefined, samples => 50}, undefined),
    ?assert(T1 < T2).

errors() ->
    [{doc, "Tests various error conditions"}].

errors(Config) when is_list(Config) ->
    ?assertException(error, {generate, {parse, init, _}},
        erlperf:run(#{runner => {erlang, node, []}, init => []})),
    ?assertException(error, {generate, {parse, runner, _}},
        erlperf:run(#{runner => []})),
    ?assertException(error, {generate, {parse, runner, _}},
        erlperf:run(#{runner => {[]}})).

mfa_squeeze() ->
    [{timetrap, {seconds, 120}}].

mfa_squeeze(Config) when is_list(Config) ->
    case erlang:system_info(schedulers_online) of
        LowCPU when LowCPU < 3 ->
            skip;
        HaveCPU ->
            {QPS, CPU} = erlperf:run({rand, uniform, [1]}, #{sample_duration => 50, warmup => 1}, #{}),
            ct:pal("Schedulers: ~b, detected: ~p, QPS: ~p", [HaveCPU, CPU, QPS]),
            ?assert(QPS > 0),
            ?assert(CPU > 1)
    end.

%%--------------------------------------------------------------------
%% command-line testing

parse_qps(QPST, "") -> list_to_integer(QPST);
parse_qps(QPST, "Ki") -> list_to_integer(QPST) * 1000;
parse_qps(QPST, "Mi") -> list_to_integer(QPST) * 1000000;
parse_qps(QPST, "Gi") -> list_to_integer(QPST) * 1000000000.

parse_duration(TT, "ns") -> list_to_integer(TT) div 1000;
parse_duration(TT, "us") -> list_to_integer(TT);
parse_duration(TT, "ms") -> list_to_integer(TT) * 1000;
parse_duration(TT, "s") -> list_to_integer(TT) * 1000000.

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
                     [Code, ConcT, QPST, TT, TTU, Rel] ->
                         {Code, list_to_integer(ConcT), parse_qps(QPST, ""), parse_duration(TT, TTU),
                             list_to_integer(lists:droplast(Rel))};
                     [Code, ConcT, QPST, QU, TT, TTU, Rel] ->
                         {Code, list_to_integer(ConcT), parse_qps(QPST, QU), parse_duration(TT, TTU),
                             list_to_integer(lists:droplast(Rel))}
                 end
             end || Ln <- Lines];
        _BadRet ->
            ct:pal(Out),
            ?assert(false)
    end.

% erlperf 'timer:sleep(1). -d 100'
cmd_line_simple(Config) when is_list(Config) ->
    Code = "timer:sleep(1).",
    Out = capture_io(fun() -> erlperf_cli:main([Code, "-d", "100"]) end),
    [{Code, 1, C, T}] = parse_out(Out),
    ?assert(C > 25 andalso C < 110, {qps, C}),
    ?assert(T > 1000 andalso T < 3000, {time, T}).

% erlperf 'timer:sleep(1). -v'
cmd_line_verbose(Config) when is_list(Config) ->
    Code = "timer:sleep(1).",
    Out = capture_io(fun () -> erlperf_cli:main([Code, "-v"]) end),
    Lines = filtersplit(Out, "\n"),
    %% TODO: actually verify that stuff printed is monitoring stuff
    ?assert(length(Lines) > 3),
    %% parse last 2 lines
    [{Code, 1, C, T}] = parse_out(lists:join("\n", lists:sublist(Lines, length(Lines) - 1, 2))),
    ?assert(C > 250 andalso C < 1101, {qps, C}),
    ?assert(T > 1000 andalso T < 3000, {time, T}).

% erlperf 'timer:sleep(1).' 'timer:sleep(2).' -d 100 -s 5 -w 1 -c 2
cmd_line_compare(Config) when is_list(Config) ->
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

cmd_line_squeeze() ->
    [{doc, "Tests concurrency test via command line"}, {timetrap, {seconds, 30}}].

% erlperf 'timer:sleep(1).' --sample_duration 50 --squeeze --min 2 --max 4 --threshold 2
cmd_line_squeeze(Config) when is_list(Config) ->
    Out = capture_io(
        fun () -> erlperf_cli:main(["timer:sleep(1).", "--duration", "50", "--squeeze", "--min", "2", "--max", "4", "--threshold", "2"]) end),
    [{_Code, 4, C, T}] = parse_out(Out),
    ?assert(C > 50 andalso C < 220, {qps, C}),
    ?assert(T > 1000 andalso T < 3000, {time, T}).

% erlperf -q
cmd_line_usage(Config) when is_list(Config) ->
    Out = capture_io(fun () -> erlperf_cli:main(["-q"]) end),
    Line1 = "Error: erlperf: required argument missing: code",
    ?assertEqual(Line1, lists:sublist(Out, length(Line1))),
    Out2 = capture_io(fun () -> erlperf_cli:main(["--un code"]) end),
    ?assertEqual("Error: erlperf: unrecognised argument: --un code", lists:sublist(Out2, 48)),
    ok.

% erlperf '{file,_}=code:is_loaded(pool).' --init 'code:ensure_loaded(pool).' --done 'code:purge(pool), code:delete(pool).'
cmd_line_init(Config) when is_list(Config) ->
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
cmd_line_double(Config) when is_list(Config) ->
    Code = "runner(X)->timer:sleep(X).",
    Out = capture_io(fun () -> erlperf_cli:main([Code, "--init_runner", "1.", Code, "--init_runner", "2.", "-s", "2",
        "--duration", "100"]) end),
    [{Code, 1, C, T, R}, {Code, 1, C2, T2, R2}] = parse_out(Out),
    ?assert(C > 25 andalso C < 110, {qps, C}),
    ?assert(C2 > 25 andalso C2 < 55, {qps, C2}),
    ?assert(T < T2),
    ?assert(R > R2).

cmd_line_triple(Config) when is_list(Config) ->
    Out = capture_io(fun () -> erlperf_cli:main(["timer:sleep(1).", "-s", "2", "--duration", "100",
        "timer:sleep(2).", "timer:sleep(3)."]) end),
    [_, _, {_, 1, C3, _T3, R3}] = parse_out(Out),
    ?assert(C3 > 20 andalso C3 < 30, {"expected between 20 and 30, got", C3}),
    ?assert(R3 > 40 andalso R3 < 60, {"expected between 40 and 60, got", R3}),
    ok.

% erlperf 'runner(Arg) -> ok = pg:join(Arg, self()), ok = pg:leave(Arg, self()).' --init_runner 'pg:create(self()), self().'
cmd_line_pg(Config) when is_list(Config) ->
    ?assertEqual(undefined, whereis(scope)), %% ensure scope is not left
    Code = "runner(S)->pg:join(S,g,self()),pg:leave(S,g,self()).",
    Out = capture_io(fun () -> erlperf_cli:main(
        [Code, "--init_runner", "{ok,Scope}=pg:start_link(scope),Scope."])
                                  end),
    ?assertEqual(undefined, whereis(scope)), %% ensure runner exited
    [{_Code, 1, C, _T}] = parse_out(Out),
    ?assert(C > 100, {qps, C}).

% erlperf '{rand, uniform, [4]}'
cmd_line_mfa(Config) when is_list(Config) ->
    Code = "{rand,uniform,[4]}",
    Out = capture_io(fun () -> erlperf_cli:main([Code]) end),
    [{Code, 1, _C, _T}] = parse_out(Out).

% erlperf 'runner(Arg) -> ok = pg2:join(Arg, self()), ok = pg2:leave(Arg, self()).' --init 'ets:file2tab("pg2.tab").'
cmd_line_recorded(Config) ->
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