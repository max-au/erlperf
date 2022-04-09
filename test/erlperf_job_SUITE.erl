%%% @copyright (c) 2019-2022 Maxim Fedorov
%%% @doc
%%% Tests all combinations of code maps accepted by erlperf_job
%%% @end
-module(erlperf_job_SUITE).
-author("maximfca@gmail.com").

%% Include stdlib header to enable ?assert() for readable output
-include_lib("stdlib/include/assert.hrl").

%% Test server callbacks
-export([
    suite/0,
    all/0,
    groups/0
]).

%% Test cases
-export([
    overhead/0, overhead/1,
    runner_code/1, runner_mfa/1, runner_fun/1, runner_mod_fun/1,
    runner_fun1/1, runner_fun2/1, runner_code_fun/1, runner_code_fun1/1,
    runner_code_fun2/1, runner_code_name2/1,
    %% internal export
    sleep/1
]).

suite() ->
    [{timetrap, {minutes, 1}}].

groups() ->
    [{variants, [parallel], [runner_code, runner_mfa, runner_fun, runner_mod_fun,
        runner_fun1, runner_fun2, runner_code_fun, runner_code_fun1,
        runner_code_fun2, runner_code_name2]}].

all() ->
    [{group, variants}, overhead].

sleep(Time) ->
    timer:sleep(Time), Time.

overhead() ->
    [{doc, "Measures bound number of iterations instead of speecific duration"}].

overhead(Config) when is_list(Config) ->
    SampleCount = 10000000,
    %% special case: code with no init/state/MFA/fun/... can be optimised
    %%  to a simple "for-loop" and get executed with the lease overhead
    {ok, Job} = erlperf_job:start_link(#{runner => "rand:uniform(1000)."}),
    Sampler = erlperf_job:handle(Job),
    TimeUs = erlperf_job:measure(Job, SampleCount),
    %% measure the same thing now with continuous benchmark
    ok = erlperf_job:set_concurrency(Job, 1),
    %% fetch a sample
    Start = erlperf_job:sample(Sampler),
    timer:sleep(1000),
    Finish = erlperf_job:sample(Sampler),
    gen:stop(Job),
    ContinuousQPS = Finish - Start,
    TimeProratedQPS = SampleCount * 1000000 div TimeUs,
    Effy = ContinuousQPS * 100 div TimeProratedQPS,
    ct:pal("Continuous benchmarking efficiency: ~b% (~b time for ~b, ~b continuous)~n",
        [Effy, TimeUs, SampleCount, ContinuousQPS]),
    ?assert(Effy > 50, {efficiency, Effy}).

%% code below is a simple hack to make run with some parallelism. Original code
%%  just had RunnerVariants as a list comprehension.

runner_code(Config) when is_list(Config) ->
    variants("timer:sleep(1).", ?FUNCTION_NAME).

runner_mfa(Config) when is_list(Config) ->
    variants({timer, sleep, [1]}, ?FUNCTION_NAME).

runner_fun(Config) when is_list(Config) ->
    variants(fun () -> timer:sleep(1) end, ?FUNCTION_NAME).

runner_mod_fun(Config) when is_list(Config) ->
    variants(fun ?MODULE:sleep/1, ?FUNCTION_NAME).

runner_fun1(Config) when is_list(Config) ->
    variants(fun (1) -> timer:sleep(1), 1 end, ?FUNCTION_NAME).

runner_fun2(Config) when is_list(Config) ->
    variants(fun (1, 1) -> timer:sleep(1), 1 end, ?FUNCTION_NAME).

runner_code_fun(Config) when is_list(Config) ->
    variants("runner() -> timer:sleep(1).", ?FUNCTION_NAME).

runner_code_fun1(Config) when is_list(Config) ->
    variants("runner(1) -> timer:sleep(1), 1.", ?FUNCTION_NAME).

runner_code_fun2(Config) when is_list(Config) ->
    variants("runner(1, 1) -> timer:sleep(1), 1.", ?FUNCTION_NAME).

runner_code_name2(Config) when is_list(Config) ->
    variants("baz(1, 1) -> timer:sleep(1), 1.", ?FUNCTION_NAME).

variants(Runner, ProcName) ->
    ProcStr = atom_to_list(ProcName),
    Sep = io_lib:format("~n    ", []),
    %% register this process to send messages from init/init_runner/done
    register(ProcName, self()),
    %%
    InitVariants = [
        undefined,
        {erlang, send, [ProcName, init]},
        fun () -> erlang:send(ProcName, init) end,
        lists:concat(["erlang:send(" ++ ProcStr ++ ", init)."]),
        lists:concat(["init() -> erlang:send(" ++ ProcStr ++ ", init)."]),
        lists:concat(["foo() -> erlang:send(" ++ ProcStr ++ ", init)."])
    ],
    InitRunnerVariants = [
        undefined,
        {erlang, send, [ProcName, 1]},
        fun () -> erlang:send(ProcName, 1) end,
        fun (init) -> erlang:send(ProcName, 1) end,
        "erlang:send(" ++ ProcStr ++ ", 1).",
        lists:concat(["init_runner() ->", Sep, "erlang:send(" ++ ProcStr ++ ", 1)."]),
        lists:concat(["init_runner(init) ->", Sep, "erlang:send(" ++ ProcStr ++ ", 1)."]),
        lists:concat(["bar(init) ->", Sep, "erlang:send(" ++ ProcStr ++ ", 1)."])
    ],
    DoneVariants = [
        undefined,
        {erlang, send, [ProcName, done]},
        fun () -> erlang:send(ProcName, done) end,
        fun (init) -> erlang:send(ProcName, done) end,
        lists:concat(["erlang:send(" ++ ProcStr ++ ", done)."]),
        lists:concat(["done() -> erlang:send(" ++ ProcStr ++ ", done)."]),
        lists:concat(["done(init) -> erlang:send(" ++ ProcStr ++ ", done)."]),
        lists:concat(["buzz(init) -> erlang:send(" ++ ProcStr ++ ", done)."])
    ],
    %% try all variants
    Variants = [#{init => Init, init_runner => InitRunner, runner => Runner, done => Done}
        || Init <- InitVariants, InitRunner <- InitRunnerVariants, Done <- DoneVariants],
    %% filter "undefined" entries from the map
    Maps = [maps:filter(fun (_Key, Value) -> Value =/= undefined end, Variant)
        || Variant <- Variants],

    %% generate code for each variant and measure performance
    [measure_variant(Variant)|| Variant <- Maps].

measure_variant(Code) ->
    try
        ct:log("Source: ~200p~n", [Code]),
        {ok, Job} = erlperf_job:start_link(Code),
        %% must not start the /1 runners
        %%
        Sampler = erlperf_job:handle(Job),
        is_map_key(init, Code) andalso receive init -> ok after 1000 -> throw({init, timeout}) end,
        %% ensure it does not crash attempting to do a single measurement
        TimeUs = erlperf_job:measure(Job, 10),
        ?assert(TimeUs > 0),
        %%
        ok = erlperf_job:set_concurrency(Job, 1),
        %% wait for 1 job to get started
        is_map_key(init_runner, Code) andalso receive 1 -> ok after 1000 -> throw({init_runner, timeout}) end,
        %% fetch a single 50 ms sample
        timer:sleep(50),
        Sample = erlperf_job:sample(Sampler),
        %% stop the job
        gen:stop(Job),
        is_map_key(done, Code) andalso receive done -> ok after 1000 -> throw({done, timeout}) end,
        %% timer:sleep must be run between 5 and 51 times - very relaxed, but CIs are notoriously slow...
        ?assert(Sample > 5 andalso Sample < 51, {sample, Sample})
    catch error:{generate, {What, Arity, requires, Dependency}} ->
        %% verify this combination is indeed invalid
        ?assertNot(is_map_key(Dependency, Code)),
        ?assert((What =:= init_runner andalso Arity =:= 1) orelse (What =:= runner andalso Arity > 0)
            orelse (What =:= done andalso Arity =:= 1))
        %% io:format(user, "Invalid combination: ~s/~b requires ~s~n~n", [What, Arity, Dependency])
    end.
