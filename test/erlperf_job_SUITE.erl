%%% @copyright (c) 2019-2023 Maxim Fedorov
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

%% Runner variants test cases
-export([
    runner_code/1, runner_mfa/1, runner_mfa_list/1, runner_fun/1, runner_mod_fun/1,
    runner_fun1/1, runner_fun2/1, runner_code_fun/1, runner_code_fun1/1,
    runner_code_fun2/1, runner_code_name2/1]).

%% Basic test cases
-export([priority/0, priority/1, overhead/0, overhead/1, module/0, module/1]).

%% internal exports
-export([recv/0, recv/1]).

suite() ->
    [{timetrap, {seconds, 120}}].

groups() ->
    [{variants, [parallel], [runner_code, runner_mfa, runner_mfa_list, runner_fun, runner_mod_fun,
        runner_fun1, runner_fun2, runner_code_fun, runner_code_fun1,
        runner_code_fun2, runner_code_name2]}].

all() ->
    [{group, variants}, priority, overhead, module].

%%--------------------------------------------------------------------
%% Convenience helpers

recv() ->
    recv(check).

recv(check) ->
    receive
        {Ref, ReplyTo} ->
            ReplyTo ! Ref
    end.

%%--------------------------------------------------------------------
%% Runner definitions


%%--------------------------------------------------------------------
%% TEST CASES

priority() ->
    [{doc, "Tests job controller priority setting"}].

priority(Config) when is_list(Config) ->
    {ok, Job} = erlperf_job:start_link(#{runner => {?MODULE, recv, []}}),
    high = erlperf_job:set_priority(Job, max),
    ok = erlperf_job:set_concurrency(Job, 1),
    {priority, max} = erlang:process_info(Job, priority),
    ok = erlperf_job:set_concurrency(Job, 0),
    {priority, normal} = erlang:process_info(Job, priority),
    gen:stop(Job).

overhead() ->
    [{doc, "Compares timed and continuous mode, may be failing sporadically"}].

overhead(Config) when is_list(Config) ->
    SampleCount = 10000000,
    %% must use code (it's the fastest method), cannot use sleep (imprecise and slow),
    %% and cannot rely on message passing for it cannot control timing
    {ok, Job} = erlperf_job:start_link(#{runner => "rand:uniform(1000)."}),
    Sampler = erlperf_job:handle(Job),
    TimeUs = erlperf_job:measure(Job, SampleCount),
    %% measure the same thing now with continuous benchmark
    ok = erlperf_job:set_concurrency(Job, 1),
    %% fetch a sample sleeping ~ same time as for timed run
    Start = erlperf_job:sample(Sampler),
    timer:sleep(TimeUs div 1000 + 1),
    Finish = erlperf_job:sample(Sampler),
    gen:stop(Job),
    ContinuousQPS = Finish - Start,
    Effy = ContinuousQPS * 100 div SampleCount,
    ct:pal("Continuous benchmarking efficiency: ~b% (~b time for ~b, ~b continuous)~n",
        [Effy, TimeUs, SampleCount, ContinuousQPS]),
    ?assert(Effy > 50, {efficiency, Effy}).

module() ->
    [{doc, "Tests that generated module gets unloaded after job stops"}].

module(Config) when is_list(Config) ->
    sys:module_info(), %% just in case if it wasn't loaded
    PreJob = code:all_loaded(),
    {ok, Job} = erlperf_job:start_link(#{runner => "ok."}),
    InJob = code:all_loaded() -- PreJob,
    gen:stop(Job),
    PostJob = code:all_loaded(),
    ?assertEqual([], PostJob -- PreJob),
    ?assert(length(InJob) == 1, InJob).

%%--------------------------------------------------------------------
%% Code map variations

%% code below is a simple hack to make run with some parallelism. Original code
%%  just had RunnerVariants as a list comprehension.

runner_code(Config) when is_list(Config) ->
    variants("erlperf_job_SUITE:recv().", ?FUNCTION_NAME).

runner_mfa(Config) when is_list(Config) ->
    variants({?MODULE, recv, [check]}, ?FUNCTION_NAME).

runner_mfa_list(Config) when is_list(Config) ->
    variants([{?MODULE, recv, [check]}, {erlang, unique_integer, []}], ?FUNCTION_NAME).

runner_fun(Config) when is_list(Config) ->
    variants(fun () -> recv(check) end, ?FUNCTION_NAME).

runner_mod_fun(Config) when is_list(Config) ->
    variants(fun ?MODULE:recv/0, ?FUNCTION_NAME).

runner_fun1(Config) when is_list(Config) ->
    variants(fun (1) -> recv(check), 1 end, ?FUNCTION_NAME).

runner_fun2(Config) when is_list(Config) ->
    variants(fun (1, 1) -> recv(check), 1 end, ?FUNCTION_NAME).

runner_code_fun(Config) when is_list(Config) ->
    variants("runner() -> erlperf_job_SUITE:recv(check).", ?FUNCTION_NAME).

runner_code_fun1(Config) when is_list(Config) ->
    variants("runner(1) -> erlperf_job_SUITE:recv(check), 1.", ?FUNCTION_NAME).

runner_code_fun2(Config) when is_list(Config) ->
    variants("runner(1, 1) -> erlperf_job_SUITE:recv(check), 1.", ?FUNCTION_NAME).

runner_code_name2(Config) when is_list(Config) ->
    variants("baz(1, 1) -> erlperf_job_SUITE:recv(check), 1.", ?FUNCTION_NAME).

variants(Runner, ProcName) ->
    ProcStr = atom_to_list(ProcName),
    Sep = io_lib:format("~n    ", []),
    %% register this process to send messages from init/init_runner/done
    register(ProcName, self()),
    %%
    InitVariants = [
        undefined,
        {erlang, send, [ProcName, init]},
        fun () -> erlang:send(ProcName, {init, self()}) end,
        lists:concat(["erlang:send(" ++ ProcStr ++ ", {init, self()})."]),
        lists:concat(["init() -> erlang:send(" ++ ProcStr ++ ", {init, self()})."]),
        lists:concat(["foo() -> erlang:send(" ++ ProcStr ++ ", {init, self()})."])
    ],
    InitRunnerVariants = [
        undefined,
        {erlang, send, [ProcName, 1]},
        fun () -> erlang:send(ProcName, 1) end,
        fun (_) -> erlang:send(ProcName, 1) end,
        "erlang:send(" ++ ProcStr ++ ", 1).",
        lists:concat(["init_runner() ->", Sep, "erlang:send(" ++ ProcStr ++ ", 1)."]),
        lists:concat(["init_runner(_) ->", Sep, "erlang:send(" ++ ProcStr ++ ", 1)."]),
        lists:concat(["bar(_) ->", Sep, "erlang:send(" ++ ProcStr ++ ", 1)."])
    ],
    DoneVariants = [
        undefined,
        {erlang, send, [ProcName, done]},
        fun () -> erlang:send(ProcName, done) end,
        fun (_) -> erlang:send(ProcName, done) end,
        lists:concat(["erlang:send(" ++ ProcStr ++ ", done)."]),
        lists:concat(["done() -> erlang:send(" ++ ProcStr ++ ", done)."]),
        lists:concat(["done(_) -> erlang:send(" ++ ProcStr ++ ", done)."]),
        lists:concat(["buzz(_) -> erlang:send(" ++ ProcStr ++ ", done)."])
    ],
    %% try all variants
    Variants = [#{init => Init, init_runner => InitRunner, runner => Runner, done => Done}
        || Init <- InitVariants, InitRunner <- InitRunnerVariants, Done <- DoneVariants],
    %% filter "undefined" entries from the map
    Maps = [maps:filter(fun (_Key, Value) -> Value =/= undefined end, Variant)
        || Variant <- Variants],

    %% generate code for each variant and measure performance
    [measure_variant(Variant) || Variant <- Maps].

measure_variant(Code) ->
    try
        {ok, Job} = erlperf_job:start_link(Code),
        Handle = erlperf_job:handle(Job),
        %% wait for "init" function to complete, when possible, ensure it's sent from the job process
        is_map_key(init, Code) andalso
            receive
                InitResult ->
                    ?assert((InitResult =:= init) orelse (InitResult =:= {init, Job}), {bad_init_result, InitResult})
            after 1000 -> throw({init, timeout})
            end,
        %% ensure it does not crash attempting to do a single measurement,
        %% basic sanity check that timed mode returns time > 0
        TimeUs = measure_timed(Job, is_map_key(init_runner, Code)),
        ?assert(TimeUs > 1, {timed_mode_too_fast, TimeUs}),
        %%
        ok = erlperf_job:set_concurrency(Job, 1),
        %% wait for 1 worker to get started
        is_map_key(init_runner, Code) andalso expect_message(1, init_runner),
        %% whitebox...
        {erlperf_job_state, _, _, [Worker], _, _, _} = sys:get_state(Job),
        %% by now, function may have been _called_ once (but not yet returned)
        Before = erlperf_job:sample(Handle),
        ?assert(Before =:= 0 orelse Before =:= 1, {unexpected_sample, Before}),
        BumpCount = 50,
        %% do exactly BumpCount iterations
        [Worker ! {Seq, self()} || Seq <- lists:seq(1, BumpCount)],
        %% receive BumpCount replies
        [receive Seq -> ok end || Seq <- lists:seq(1, BumpCount)],
        %% by now, extra 50 calls happened
        After = erlperf_job:sample(Handle),
        ?assert(After >= BumpCount, {unexpected_after, After}),

        %% stop the job
        gen:stop(Job),
        is_map_key(done, Code) andalso expect_message(done, done),
        %% must not have anything in the message queue
        receive
            Unexpected ->
                ?assert(false, {unexpected_message, Unexpected})
        after 0 -> ok
        end
    catch error:{generate, {What, Arity, requires, Dependency}} ->
        %% verify this combination is indeed invalid
        ?assertNot(is_map_key(Dependency, Code)),
        ?assert((What =:= init_runner andalso Arity =:= 1) orelse (What =:= runner andalso Arity > 0)
            orelse (What =:= done andalso Arity =:= 1))
        %% io:format(user, "Invalid combination: ~s/~b requires ~s~n~n", [What, Arity, Dependency])
    end.

expect_message(Expect, Operation) ->
    receive
        Message ->
            ?assertEqual(Expect, Message, {Operation, Message})
    after
        1000 ->
            throw({Operation, timeout})
    end.

measure_timed(Job, InitRunnerPresent) ->
    Iterations = 10,
    Control = self(),
    spawn_link(
        fun () ->
            TimeUs = erlperf_job:measure(Job, Iterations),
            Control ! {time, TimeUs}
        end),

    %% timed mode starts exactly 1 worker
    InitRunnerPresent andalso expect_message(1, init_runner),
    Worker = find_timed_worker(Job),

    %% send exactly "iterations" messages
    [Worker ! {Seq, self()} || Seq <- lists:seq(1, Iterations)],
    [receive Seq -> ok end || Seq <- lists:seq(1, Iterations)],
    receive
        {time, Time} ->
            Time
    end.

find_timed_worker(Job) ->
    {erlperf_job_state, _, _, _, TimedWorkers, _, _} = sys:get_state(Job),
    case map_size(TimedWorkers) of
        1 -> hd(maps:keys(TimedWorkers));
        0 -> timer:sleep(1), find_timed_worker(Job)
    end.
