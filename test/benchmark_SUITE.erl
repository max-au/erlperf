%%%-------------------------------------------------------------------
%%% @author Maxim Fedorov <maximfca@gmail.com>
%%% @copyright (c) 2019 Maxim Fedorov
%%% @doc
%%%     Tests erlperf
%%% @end
%%% -------------------------------------------------------------------

-module(benchmark_SUITE).

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
    {ok, Apps} = application:ensure_all_started(erlperf),
    [{apps, Apps} | Config].

end_per_suite(Config) ->
    [application:stop(App) || App <- ?config(apps, Config)],
    ok.

init_per_testcase(_TestCase, Config) ->
    Config.

end_per_testcase(_TestCase, _Config) ->
    ok.

groups() ->
    [
        {benchmark, [parallel], [
            mfa, mfa_list, mfa_fun, mfa_fun1,
            code, code_fun, code_fun1,
            mfa_init, mfa_fun_init,
            code_gen_server,
            mfa_concurrency, mfa_no_concurrency,
            code_extra_node]},
        {squeeze, [], [
            mfa_squeeze
        ]}
    ].

all() ->
    [{group, benchmark}, {group, squeeze}].

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
    C = benchmark:run({timer, sleep, [1]}),
    ?assert(C > 250 andalso C < 1101).

mfa_list(_Config) ->
    C = benchmark:run([{rand, seed, [exrop, 1]}, {rand, uniform, [20]}, {timer, sleep, [1]}]),
    ?assert(C > 250 andalso C < 1101).

mfa_fun(_Config) ->
    C = benchmark:run(fun () -> timer:sleep(1) end),
    ?assert(C > 250 andalso C < 1101).

mfa_fun1(_Config) ->
    C = benchmark:run(fun (undefined) -> timer:sleep(1); (ok) -> timer:sleep(1) end),
    ?assert(C > 250 andalso C < 1101).

code(_Config) ->
    C = benchmark:run("timer:sleep(1)."),
    ?assert(C > 250 andalso C < 1101).

code_fun(_Config) ->
    C = benchmark:run("runner() -> timer:sleep(1)."),
    ?assert(C > 250 andalso C < 1101).

code_fun1(_Config) ->
    C = benchmark:run("runner(undefined) -> timer:sleep(1)."),
    ?assert(C > 250 andalso C < 1101).

mfa_init(_Config) ->
    C = benchmark:run({
        fun (1) -> timer:sleep(1) end,
        #{
            init_runner => {erlang, abs, [-1]}
        }}),
    ?assert(C > 250 andalso C < 1101).

mfa_fun_init(_Config) ->
    C = benchmark:run({
        {timer, sleep, []},
        #{
            init => fun () -> ok end,
            init_runner => fun (ok) -> 1 end
        }}),
    ?assert(C > 250 andalso C < 1101).

code_gen_server(_Config) ->
    C = benchmark:run({
        "run(Pid) -> gen_server:call(Pid, {sleep, 1}).",
        #{
            init => "Pid = " ++ atom_to_list(?MODULE) ++ ":start_link(), register(server, Pid), Pid.",
            init_runner => "local(Pid) when is_pid(Pid) -> Pid.",
            done => "stop(Pid) -> gen_server:stop(Pid)."
        }
    }),
    ?assertEqual(undefined, whereis(server)),
    ?assert(C > 250 andalso C < 1101).

mfa_concurrency(_Config) ->
    C = benchmark:run({timer, sleep, [1]}, #{concurrency => 2}),
    ?assert(C > 500 andalso C < 2202).

mfa_no_concurrency(_Config) ->
    C = benchmark:run(
        {
            fun (Pid) -> gen_server:call(Pid, {sleep, 1}) end,
            #{
                init => {?MODULE, start_link, []},
                init_runner => fun(Pid) -> Pid end,
                done => {gen_server, stop, []}
            }
        },
        #{concurrency => 4}),
    ?assert(C > 250 andalso C < 1101).

code_extra_node(_Config) ->
    C = benchmark:run(
        {
            "{ok, Timer} = application:get_env(kernel, test), timer:sleep(Timer).",
            #{
                init => "application:set_env(kernel, test, 1)."
            }
        },
        #{concurrency => 2, isolation => node}),
    ?assertEqual(undefined, application:get_env(kernel, test)),
    ?assert(C > 500 andalso C < 2202).


mfa_squeeze() ->
    [{timetrap, {seconds, 120}}].

mfa_squeeze(_Config) ->
    {QPS, CPU} = benchmark:run({rand, uniform, [1]}, #{sample_duration => 100, warmup => 1}, #{}),
    HaveCPU = erlang:system_info(schedulers_online),
    ct:pal("Schedulers: ~b, detected: ~p, QPS: ~p", [HaveCPU, CPU, QPS]),
    ?assert(QPS > 0),
    ?assert(CPU > 1).
