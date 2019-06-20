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
            crasher, undefer,
            errors,
            compare,
            formatters
        ]},
        {cmdline, [parallel], [
            cmd_line_simple,
            cmd_line_compare,
            cmd_line_squeeze,
            cmd_line_usage
        ]},
        {squeeze, [], [
            mfa_squeeze
        ]}
    ].

all() ->
    [{group, benchmark}, {group, cmdline}, {group, squeeze}].

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

undefer() ->
    [{doc, "Tests job undefs - e.g. wrong module name"}].

undefer(_Config) ->
    ?assertException(error, {badmatch, {error, {{module_not_found, '$cannot_be_this'}, _}}},
        erlperf:run({'$cannot_be_this', throw, []}, #{concurrency => 2})).

errors() ->
    [{doc, "Tests various error conditions"}].

errors(_Config) ->
    ?assertException(error, {badmatch, {error, {"empty callable", _}}},
        erlperf:run(#{runner => {erlang, node, []}, init => []})),
    ?assertException(error, {badmatch, {error, {"cannot mix source and non-source forms", _}}},
        erlperf:run(#{runner => {erlang, node, []}, init => "init() -> ok."})),
    ?assertException(error, {badmatch, {error, {"empty callable", _}}},
        erlperf:run(#{runner => []})),
    ?assertException(error, {badmatch, {error, {"empty callable", _}}},
        erlperf:run(#{runner => {[]}})).

mfa_squeeze() ->
    [{timetrap, {seconds, 120}}].

mfa_squeeze(_Config) ->
    ?assert(erlang:system_info(schedulers_online) > 1), % makes no sense to run with 1 scheduler
    {QPS, CPU} = erlperf:run({rand, uniform, [1]}, #{sample_duration => 100, warmup => 1}, #{}),
    HaveCPU = erlang:system_info(schedulers_online),
    ct:pal("Schedulers: ~b, detected: ~p, QPS: ~p", [HaveCPU, CPU, QPS]),
    ?assert(QPS > 0),
    ?assert(CPU > 1).

%%--------------------------------------------------------------------
%% command-line testing

% erlperf 'timer:sleep(1).'
% Code               Concurrency   Throughput
% timer:sleep(1).              1          498
cmd_line_simple(_Config) ->
    Out = test_helpers:capture_io(fun () -> erlperf:main(["timer:sleep(1)."]) end),
    ?assertNotEqual([], Out),
    ok.

% erlperf 'rand:uniform().' 'crypto:strong_rand_bytes(2).' -samples 10 -warmup 1
cmd_line_compare(_Config) ->
    Out = test_helpers:capture_io(
        fun () -> erlperf:main(["timer:sleep(1).", "timer:sleep(2).", "-s", "5", "-d", "100", "-w", "1"]) end),
    ?assertNotEqual([], Out),
    % Code            Concurrency   Throughput   Relative
    % timer:sleep().            2          950       100%
    % timer:sleep(2).           2          475        50%
    ok.


cmd_line_squeeze() ->
    [{doc, "Tests concurrency test via command line"}, {timetrap, {seconds, 30}}].

cmd_line_squeeze(_Config) ->
    Out = test_helpers:capture_io(
        fun () -> erlperf:main(["timer:sleep(1).", "--squeeze", "--min", "2", "--max", "4", "--threshold", "2"]) end),
    ?assertNotEqual([], Out),
    ok.

cmd_line_usage(_Config) ->
    Out = test_helpers:capture_io(fun () -> erlperf:main(["-q"]) end),
    ?assertEqual("Usage", lists:sublist(hd(Out), 5)),
    ok.

compare(_Config) ->
    [C1, C2] = erlperf:compare(["timer:sleep(1).", "timer:sleep(2)."], #{}),
    ?assert(C1 > C2).

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
