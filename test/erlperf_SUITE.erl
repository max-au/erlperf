%%%-------------------------------------------------------------------
%%% @author Maxim Fedorov <maximfca@gmail.com>
%%% @copyright (c) 2019 Maxim Fedorov
%%% @doc
%%%     Tests benchmark module, machine-readable output for benchmarks.
%%% @end
%%% -------------------------------------------------------------------

-module(erlperf_SUITE).

%% Common Test headers
-include_lib("common_test/include/ct.hrl").

%% Include stdlib header to enable ?assert() for readable output
-include_lib("stdlib/include/assert.hrl").

-compile(nowarn_export_all).
-compile(export_all).

-behaviour(gen_server).


%%--------------------------------------------------------------------
%% COMMON TEST CALLBACK FUNCTIONS

suite() ->
    [{timetrap, {seconds, 10}}].

init_per_suite(Config) ->
    Config.

end_per_suite(Config) ->
    test_helpers:maybe_undistribute(Config).

init_per_group(cmdline, Config) ->
    Config;
init_per_group(_, Config) ->
    test_helpers:ensure_started(erlperf, Config).

end_per_group(cmdline, Config) ->
    Config;
end_per_group(_, Config) ->
    test_helpers:ensure_stopped(Config).

init_per_testcase(code_extra_node, Config) ->
    test_helpers:ensure_distributed(Config);
init_per_testcase(_TestCase, Config) ->
    Config.

end_per_testcase(_TestCase, _Config) ->
    ok.

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
            errors,
            formatters
        ]},
        {cmdline, [sequential], [
            cmd_line_simple,
            cmd_line_verbose,
            cmd_line_compare,
            cmd_line_squeeze,
            cmd_line_usage,
            cmd_line_init,
            cmd_line_pg2,
            cmd_line_mfa,
            cmd_line_recorded,
            cmd_line_profile
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
    error(badarg).

start_link() ->
    {ok, Pid} = gen_server:start_link(?MODULE, [], []),
    Pid.

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

mfa(_Config) ->
    C = erlperf:run({timer, sleep, [1]}),
    ?assert(C > 250 andalso C < 1101).

mfa_with_cv(_Config) ->
    C = erlperf:run({timer, sleep, [1]}, #{cv => 0.05}),
    ?assert(C > 250 andalso C < 1101).

mfa_with_tiny_cv() ->
    [{doc, "Tests benchmarking with very small coefficient of variation, potentially long"},
        {timetrap, {seconds, 60}}].

mfa_with_tiny_cv(_Config) ->
    C = erlperf:run({timer, sleep, [1]}, #{samples => 2, interval => 100, cv => 0.002}),
    ?assert(C > 250 andalso C < 1101).

mfa_list(_Config) ->
    C = erlperf:run([{rand, seed, [exrop, 1]}, {timer, sleep, [1]}, {rand, uniform, [20]}, {timer, sleep, [1]}]),
    ?assert(C > 200 andalso C < 450).

mfa_fun(_Config) ->
    C = erlperf:run(fun () -> timer:sleep(1) end),
    ?assert(C > 250 andalso C < 1101).

mfa_fun1(_Config) ->
    C = erlperf:run(fun (undefined) -> timer:sleep(1); (ok) -> timer:sleep(1) end),
    ?assert(C > 250 andalso C < 1101).

code(_Config) ->
    C = erlperf:run("timer:sleep(1)."),
    ?assert(C > 250 andalso C < 1101).

code_fun(_Config) ->
    C = erlperf:run("runner() -> timer:sleep(1)."),
    ?assert(C > 250 andalso C < 1101).

code_fun1(_Config) ->
    C = erlperf:run("runner(undefined) -> timer:sleep(1)."),
    ?assert(C > 250 andalso C < 1101).

mfa_init(_Config) ->
    C = erlperf:run(#{
        runner => fun (1) -> timer:sleep(1) end,
        init => [{rand, seed, [exrop]}, {rand, uniform, [100]}],
        init_runner => {erlang, abs, [-1]}
    }),
    ?assert(C > 250 andalso C < 1101).

mfa_fun_init(_Config) ->
    C = erlperf:run(#{
        runner => {timer, sleep, []},
        init => fun () -> ok end,
        init_runner => fun (ok) -> 1 end
    }),
    ?assert(C > 250 andalso C < 1101).

code_gen_server(_Config) ->
    C = erlperf:run(#{
        runner => "run(Pid) -> gen_server:call(Pid, {sleep, 1}).",
        init => "Pid = " ++ atom_to_list(?MODULE) ++ ":start_link(), register(server, Pid), Pid.",
        init_runner => "local(Pid) when is_pid(Pid) -> Pid.",
        done => "stop(Pid) -> gen_server:stop(Pid)."
    }),
    ?assertEqual(undefined, whereis(server)),
    ?assert(C > 250 andalso C < 1101).

mfa_concurrency(_Config) ->
    C = erlperf:run({timer, sleep, [1]}, #{concurrency => 2}),
    ?assert(C > 500 andalso C < 2202).

mfa_no_concurrency(_Config) ->
    C = erlperf:run(
        #{
            runner => fun (Pid) -> gen_server:call(Pid, {sleep, 1}) end,
            init => {?MODULE, start_link, []},
            init_runner => fun(Pid) -> Pid end,
            done => {gen_server, stop, []}
        },
        #{concurrency => 4}),
    ?assert(C > 250 andalso C < 1101).

code_extra_node(_Config) ->
    C = erlperf:run(#{
            runner => "{ok, Timer} = application:get_env(kernel, test), timer:sleep(Timer).",
            init => "application:set_env(kernel, test, 1)."
        },
        #{concurrency => 2, sample_duration => 100, isolation => #{}}),
    ?assertEqual(undefined, application:get_env(kernel, test)),
    ct:pal("~p", [C]),
    ?assert(C > 50 andalso C < 220).

crasher() ->
    [{doc, "Tests job that crashes"}].

crasher(_Config) ->
    C = erlperf:run({erlang, throw, [ball]}, #{concurrency => 2}),
    ?assertEqual(0, C).

mixed() ->
    [{doc, "Tests mixed approach when code co-exists with MFAs"}].

mixed(_Config) ->
    C = erlperf:run(#{
        runner => [{timer, sleep, [1]}, {timer, sleep, [2]}],
        init => "rand:uniform().",
        init_runner => fun (Int) -> Int end
    }),
    ?assert(C > 100 andalso C < 335).

undefer() ->
    [{doc, "Tests job undefs - e.g. wrong module name"}].

undefer(_Config) ->
    ?assertException(error, {badmatch, {error, {{module_not_found, '$cannot_be_this'}, _}}},
        erlperf:run({'$cannot_be_this', throw, []}, #{concurrency => 2})).

compare(_Config) ->
    [C1, C2] = erlperf:compare(["timer:sleep(1).", "timer:sleep(2)."], #{sample_duration => 100}),
    ?assert(C1 > C2).

errors() ->
    [{doc, "Tests various error conditions"}].

errors(_Config) ->
    ?assertException(error, {badmatch, {error, {"empty callable", _}}},
        erlperf:run(#{runner => {erlang, node, []}, init => []})),
    ?assertException(error, {badmatch, {error, {"empty callable", _}}},
        erlperf:run(#{runner => []})),
    ?assertException(error, {badmatch, {error, {"empty callable", _}}},
        erlperf:run(#{runner => {[]}})).

mfa_squeeze() ->
    [{timetrap, {seconds, 120}}].

mfa_squeeze(_Config) ->
    ?assert(erlang:system_info(schedulers_online) > 1), % makes no sense to run with 1 scheduler
    {QPS, CPU} = erlperf:run({rand, uniform, [1]}, #{sample_duration => 50, warmup => 1}, #{}),
    HaveCPU = erlang:system_info(schedulers_online),
    ct:pal("Schedulers: ~b, detected: ~p, QPS: ~p", [HaveCPU, CPU, QPS]),
    ?assert(QPS > 0),
    ?assert(CPU > 1).

%%--------------------------------------------------------------------
%% command-line testing

% erlperf 'timer:sleep(1). -d 100'
cmd_line_simple(_Config) ->
    Code = "timer:sleep(1).",
    Out = test_helpers:capture_io(fun () -> erlperf:main([Code, "-d", "100"]) end),
    [LN1, LN2] = string:split(Out, "\n"),
    ?assertEqual(["Code", "||", "QPS", "Rel"], string:lexemes(LN1, " ")),
    ?assertMatch([Code, "1", _, "100%\n"], string:lexemes(LN2, " ")),
    ok.

% erlperf 'timer:sleep(1). -v'
cmd_line_verbose(_Config) ->
    Code = "timer:sleep(1).",
    Out = test_helpers:capture_io(fun () -> erlperf:main([Code, "-v"]) end),
    Lines = string:lexemes(Out, "\n"),
    ?assert(length(Lines) > 3),
    ok.

% erlperf 'rand:uniform().' 'crypto:strong_rand_bytes(2).' -d 100 -s 5 -w 1 -c 2
cmd_line_compare(_Config) ->
    Out = test_helpers:capture_io(
        fun () -> erlperf:main(["timer:sleep(1).", "timer:sleep(2).", "-s", "5", "-d", "100", "-w", "1", "-c", "2"]) end),
    ?assertNotEqual([], Out),
    % Code            Concurrency   Throughput   Relative
    % timer:sleep().            2          950       100%
    % timer:sleep(2).           2          475        50%
    ok.

cmd_line_squeeze() ->
    [{doc, "Tests concurrency test via command line"}, {timetrap, {seconds, 30}}].

% erlperf 'timer:sleep(1).' --sample_duration 50 --squeeze --min 2 --max 4 --threshold 2
cmd_line_squeeze(_Config) ->
    Out = test_helpers:capture_io(
        fun () -> erlperf:main(["timer:sleep(1).", "--sample_duration", "50", "--squeeze", "--min", "2", "--max", "4", "--threshold", "2"]) end),
    ?assertNotEqual([], Out),
    ok.

% erlperf -q
cmd_line_usage(_Config) ->
    Out = test_helpers:capture_io(fun () -> erlperf:main(["-q"]) end),
    ?assertEqual("Usage", lists:sublist(Out, 5)),
    Out2 = test_helpers:capture_io(fun () -> erlperf:main(["--un code"]) end),
    ?assertEqual("Unrecognised", lists:sublist(Out2, 12)),
    ok.

% erlperf 'pg2:join(foo, self()), pg2:leave(foo, self()).' --init 1 'pg2:create(foo).' --done 1 'pg2:delete(foo).'
cmd_line_init(_Config) ->
    Code = "pg2:join(foo,self()),pg2:leave(foo,self()).",
    Out = test_helpers:capture_io(fun () -> erlperf:main(
        [Code, "--init", "1", "pg2:create(foo).", "--done", "1", "pg2:delete(foo)."])
                                  end),
    % verify 'done' was done
    ?assertEqual({error,{no_such_group,foo}}, pg2:get_members(foo)),
    % verify output
    [LN1, LN2] = string:split(Out, "\n"),
    ?assertEqual(["Code", "||", "QPS", "Rel"], string:lexemes(LN1, " ")),
    ?assertMatch([Code, "1", _, "100%\n"], string:lexemes(LN2, " ")),
    ok.

% erlperf 'runner(Arg) -> ok = pg2:join(Arg, self()), ok = pg2:leave(Arg, self()).' --init_runner 1 'pg2:create(self()), self().'
cmd_line_pg2(_Config) ->
    Code = "runner(Arg)->ok=pg2:join(Arg,self()),ok=pg2:leave(Arg,self()).",
    Out = test_helpers:capture_io(fun () -> erlperf:main(
        [Code, "--init_runner", "1", "pg2:create(self()), self()."])
                                  end),
    [LN1, LN2] = string:split(Out, "\n"),
    ?assertEqual(["Code", "||", "QPS", "Rel"], string:lexemes(LN1, " ")),
    ?assertMatch([Code, "1", _, "100%\n"], string:lexemes(LN2, " ")),
    ok.

% erlperf '{rand, uniform, [100]}'
cmd_line_mfa(_Config) ->
    Code = "{rand,uniform,[4]}",
    Out = test_helpers:capture_io(fun () -> erlperf:main([Code]) end),
    [LN1, LN2] = string:split(Out, "\n"),
    ?assertEqual(["Code", "||", "QPS", "Rel"], string:lexemes(LN1, " ")),
    ?assertMatch([Code, "1" | _], string:lexemes(LN2, " ")),
    ok.

% erlperf 'runner(Arg) -> ok = pg2:join(Arg, self()), ok = pg2:leave(Arg, self()).' --init 1 'ets:file2tab("pg2.tab").'
cmd_line_recorded(Config) ->
    % write down ETS table to file
    EtsFile = filename:join(?config(priv_dir, Config), "ets.tab"),
    RecFile = filename:join(?config(priv_dir, Config), "recorded.list"),
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
    Out = test_helpers:capture_io(fun () -> erlperf:main(
        [RecFile, "--init", "1", "ets:file2tab(\"" ++ EtsFile ++ "\")."])
                                  end),
    [LN1, LN2] = string:split(Out, "\n"),
    ?assertEqual(["Code", "||", "QPS", "Rel"], string:lexemes(LN1, " ")),
    ?assertMatch(["[{ets,insert,[test_ets_tab,{100,40}]},", "...]", "1" | _], string:lexemes(LN2, " ")),
    ok.

% profiler test
cmd_line_profile(_Config) ->
    Code = "runner(Arg)->ok=pg2:join(Arg,self()),ok=pg2:leave(Arg,self()).",
    Out = test_helpers:capture_io(fun () -> erlperf:main(
        [Code, "--init_runner", "1", "pg2:create(self()), self().", "--profile"])
                                  end),
    [LN1 | _] = string:split(Out, "\n"),
    ?assertEqual("Reading trace data...", LN1),
    ok.

formatters(_Config) ->
    ?assertEqual("88", erlperf:format_size(88)),
    ?assertEqual("88000", erlperf:format_number(88000)),
    ?assertEqual("881 Mb", erlperf:format_size(881 * 1024 * 1024)),
    ?assertEqual("881 Mb", erlperf:format_size(881 * 1024 * 1024)),
    ?assertEqual("123 Gb", erlperf:format_size(123 * 1024 * 1024 * 1024)),
    % rounding
    ?assertEqual("42", erlperf:format_number(42)),
    ?assertEqual("432 Ki", erlperf:format_number(431992)),
    ?assertEqual("333 Mi", erlperf:format_number(333000000)),
    ?assertEqual("999 Gi", erlperf:format_number(998500431992)).

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