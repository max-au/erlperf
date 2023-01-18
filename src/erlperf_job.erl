%%% @copyright (C) 2019-2023, Maxim Fedorov
%%% @doc
%%% Job runner, taking care of init/done, workers added and removed.
%%% Works just like a simple_one_for_one supervisor (children are
%%%   temporary runners).
%%% There are two benchmarking modes: continuous (activated by
%%%   setting non-zero concurrency), and sample-based (activated
%%%   manually and deactivated after runner does requested amount
%%%   of iterations).
%%%
%%% Job is defined with 4 functions (code map): <ul>
%%%  <li>init/0 - called once when starting the job</li>
%%%  <li>init_runner/0 - called when starting a runner process, or
%%%    init_runner/1 that accepts return value from init/0. It is
%%%    an error to omit init/0 if init_runner/1 is defined, but
%%%    it is not an error to have init_runner/0 when init/0 exists</li>
%%%  <li>runner/0 - ignores init_runner/0,1</li>
%%%  <li>runner/1 - requires init_runner/0,1 return value as initial state,
%%%    passes it as state for the next invocation (accumulator)</li>
%%%  <li>runner/2 - requires init_runner/0,1 return value as initial state,
%%%    passes accumulator as a second argument</li>
%%%  <li>done/1 - requires init/0 (and accepts its return value)</li>
%%% </ul>
%%% @end
-module(erlperf_job).
-author("maximfca@gmail.com").

-behaviour(gen_server).

%% Job API
-export([
    start/1,
    start_link/1,
    request_stop/1,
    concurrency/1,
    set_concurrency/2,
    measure/2,
    sample/1,
    handle/1,
    source/1,
    set_priority/2
]).

%% gen_server callbacks
-export([
    init/1,
    handle_call/3,
    handle_cast/2,
    handle_info/2,
    terminate/2
]).

%% MFArgs: module, function, arguments.
-type mfargs() :: {module(), atom(), [term()]}.

%% Callable: one or more MFArgs, or a function object, or source code
-type callable() ::
    mfargs() |
    [mfargs()] |
    fun() |
    fun((term()) -> term()) |
    string().

%% Benchmark code: init, init_runner, runner, done.
-type code_map() :: #{
    runner := callable(),
    init => callable(),
    init_runner => callable(),
    done => callable()
}.

%% Internal (opaque) type, please do not use
-type handle() :: {module(), non_neg_integer()}.

%% Temporary type until OTP25 is everywhere
-type server_ref() :: gen_server:server_ref().

-export_type([callable/0, code_map/0]).

%% @doc
%% Starts the benchmark instance.
%% Job starts with no workers, use set_concurrency/2 to start some.
-spec start(code_map()) -> {ok, pid()} | {error, term()}.
start(#{runner := _MustHave} = Code) ->
    gen_server:start(?MODULE, generate(Code), []).

%% @doc
%% Starts the benchmark instance and links it to caller.
%% Job starts with no workers, use set_concurrency/2 to start some.
-spec start_link(code_map()) -> {ok, pid()} | {error, term()}.
start_link(#{runner := _MustHave} = Code) ->
    gen_server:start_link(?MODULE, generate(Code), []).

%% @doc
%% Requests this job to stop. Caller should monitor the job process
%% to find our when the job has actually stopped.
-spec request_stop(server_ref()) -> ok.
request_stop(JobId) ->
    gen_server:cast(JobId, stop).

%% @doc
-spec concurrency(server_ref()) -> Concurrency :: non_neg_integer().
concurrency(JobId) ->
    gen_server:call(JobId, concurrency).

%% @doc
%% Change concurrency setting for this job.
%% Does not reset counting. May never return if init_runner
%% does not return.
-spec set_concurrency(server_ref(), non_neg_integer()) -> ok.
set_concurrency(JobId, Concurrency) ->
    gen_server:call(JobId, {set_concurrency, Concurrency}, infinity).

%% @doc
%% Executes the runner SampleCount times, returns time in microseconds it
%%  took to execute. Similar to `timer:tc'. Has less overhead compared to
%%  continuous benchmarking, therefore can be used even for very fast functions.
-spec measure(server_ref(), SampleCount :: non_neg_integer()) ->
    TimeUs :: non_neg_integer() | already_started.
measure(JobId, SampleCount) ->
    gen_server:call(JobId, {measure, SampleCount}, infinity).

%% @doc
%% Returns the sampling handle for the job.
-spec handle(server_ref()) -> handle().
handle(JobId) ->
    gen_server:call(JobId, handle).

%% @doc
%% Returns the current sample for the job, or undefined if the job has stopped.
-spec sample(handle()) -> non_neg_integer() | undefined.
sample({Module, Arity}) ->
    {call_count, Count} = erlang:trace_info({Module, Module, Arity}, call_count),
    Count.

%% @doc
%% Returns the source code that was generated for this job.
-spec source(handle()) -> [string()].
source(JobId) ->
    gen_server:call(JobId, source).

%% @doc
%% Sets job process priority when there are workers running.
%% Worker processes may utilise all schedulers, making job
%%  process to lose control over starting and stopping workers.
%% By default, job process sets 'high' priority when there are
%%  any workers running.
%% Returns the previous setting.
-spec set_priority(server_ref(), erlang:priority_level()) -> erlang:priority_level().
set_priority(JobId, Priority) ->
    gen_server:call(JobId, {priority, Priority}).

%%--------------------------------------------------------------------
%% Internal definitions

-include_lib("kernel/include/logger.hrl").

-record(exec, {
    name :: atom(),         %% generated module name (must be generated for tracing to work)
    source :: [string()],   %% module source code
    binary :: binary(),     %% generated bytecode
    init :: fun(() -> term()),  %% init function
    init_runner :: fun((term()) -> term()), %% must accept 1 argument
    runner :: {fun((term()) -> term()), non_neg_integer()},
    sample_runner :: {fun((non_neg_integer(), term()) -> term()), non_neg_integer()},
    done :: fun((term()) -> term())  %% must accept 1 argument
}).

-type exec() :: #exec{}.

-record(erlperf_job_state, {
    %% original spec
    exec :: exec(),
    %% return value of init/1
    init_result :: term(),
    %% continuous workers
    workers = [] :: [pid()],
    %% temporary workers (for sample_count call)
    sample_workers = #{} :: #{pid() => {pid(), reference()}},
    %% priority to return to when no workers left
    initial_priority :: erlang:priority_level(),
    %% priority to set when workers are running
    priority = high :: erlang:priority_level()
}).

-type state() :: #erlperf_job_state{}.

%%%===================================================================
%%% gen_server callbacks

init(#exec{name = Mod, binary = Bin, init = Init, runner = {_Fun, Arity}} = Exec) ->
    %% need to trap exits to avoid crashing and not cleaning up the loaded module
    erlang:process_flag(trap_exit, true),
    {module, Mod} = code:load_binary(Mod, Mod, Bin),
    %% run the init/0 if defined
    InitRet =
        try Init()
        catch
            Class:Reason:Stack ->
                %% clean up loaded module before crashing
                code:purge(Mod),
                code:delete(Mod),
                erlang:raise(Class, Reason, Stack)
        end,
    %% register in the monitor
    ok = erlperf_monitor:register(self(), {Mod, Arity}, 0),
    %% start tracing this module runner function
    1 = erlang:trace_pattern({Mod, Mod, Arity}, true, [local, call_count]),
    {priority, Prio} = erlang:process_info(self(), priority),
    {ok, #erlperf_job_state{exec = Exec, init_result = InitRet, initial_priority = Prio}}.

-spec handle_call(term(), {pid(), reference()}, state()) -> {reply, term(), state()}.
handle_call(handle, _From, #erlperf_job_state{exec = #exec{name = Name, runner = {_Fun, Arity}}} = State) ->
    {reply, {Name, Arity}, State};

handle_call(concurrency, _From, #erlperf_job_state{workers = Workers} = State) ->
    {reply, length(Workers), State};

handle_call({measure, SampleCount}, From, #erlperf_job_state{sample_workers = SampleWorkers,
    exec = #exec{init_runner = InitRunner, sample_runner = SampleRunner},
    init_result = IR} = State) when SampleWorkers =:= #{} ->
    {noreply, State#erlperf_job_state{sample_workers =
        start_sample_count(SampleCount, From, InitRunner, IR, SampleRunner)}};

handle_call({measure, _SampleCount}, _From, #erlperf_job_state{} = State) ->
    {reply, already_started, State};

handle_call(source, _From, #erlperf_job_state{exec = #exec{source = Source}} = State) ->
    {reply, Source, State};

handle_call({priority, Prio}, _From, #erlperf_job_state{priority = Old} = State) ->
    {reply, Old, State#erlperf_job_state{priority = Prio}};

handle_call({set_concurrency, Concurrency}, _From, #erlperf_job_state{workers = Workers} = State) ->
    {reply, ok, State#erlperf_job_state{workers = set_concurrency_impl(length(Workers), Concurrency, State)}}.

handle_cast(stop, State) ->
    {stop, normal, State}.

-spec handle_info(term(), state()) -> {noreply, state()}.
handle_info({'EXIT', SampleWorker, Reason},
    #erlperf_job_state{sample_workers = SampleWorkers} = State) when is_map_key(SampleWorker, SampleWorkers) ->
    {ReplyTo, MoreSW} = maps:take(SampleWorker, SampleWorkers),
    gen:reply(ReplyTo, Reason),
    {noreply, State#erlperf_job_state{sample_workers = MoreSW}};

handle_info({'EXIT', Worker, Reason}, #erlperf_job_state{workers = Workers} = State) when Reason =:= shutdown ->
    {noreply, State#erlperf_job_state{workers = lists:delete(Worker, Workers)}};
handle_info({'EXIT', Worker, Reason}, #erlperf_job_state{workers = Workers} = State) ->
    {stop, Reason, State#erlperf_job_state{workers = lists:delete(Worker, Workers)}}.

-spec terminate(term(), state()) -> ok.
terminate(_Reason, #erlperf_job_state{init_result = IR, workers = Workers, exec = #exec{name = Mod, done = Done}} = State) ->
    %% terminate all workers first
    set_concurrency_impl(length(Workers), 0, State),
    %% call "done" for cleanup
    try Done(IR)
    catch
        Class:Reason:Stack ->
            %% duly note, but do not crash, it is pointless at this moment
            ?LOG_ERROR("Exception while executing 'done': ~s:~0p~n~0p", [Class, Reason, Stack])
    after
        _ = code:purge(Mod),
        true = code:delete(Mod)
    end.

%%%===================================================================
%%% Internal: runner implementation

%% Single run
start_sample_count(SampleCount, ReplyTo, InitRunner, InitRet, {SampleRunner, _}) ->
    Child = erlang:spawn_link(
        fun() ->
            %% need to send a message even if init_runner fails, hence 'after'
            IRR = InitRunner(InitRet),
            T1 = erlang:monotonic_time(),
            SampleRunner(SampleCount, IRR),
            T2 = erlang:monotonic_time(),
            Time = erlang:convert_time_unit(T2 - T1, native, microsecond),
            exit(Time)
        end
    ),
    #{Child => ReplyTo}.

set_concurrency_impl(OldConcurrency, Concurrency, #erlperf_job_state{workers = Workers, init_result = IR, exec = Exec,
    priority = Prio, initial_priority = InitialPrio}) ->
    case Concurrency - OldConcurrency of
        0 ->
            Workers;
        NeedMore when NeedMore > 0 ->
            %% this process must run with higher priority to avoid being de-scheduled by runners
            OldConcurrency =:= 0 andalso erlang:process_flag(priority, Prio),
            Workers ++ add_workers(NeedMore, Exec, IR, []);
        NeedLess ->
            {Fire, Keep} = lists:split(-NeedLess, Workers),
            stop_workers(Fire),
            Keep =:= [] andalso erlang:process_flag(priority, InitialPrio),
            Keep
    end.

add_workers(0, _ExecMap, _InitRet, NewWorkers) ->
    %% ensure all new workers completed their InitRunner routine
    [receive {Worker, init_runner} -> ok end || Worker <- NewWorkers],
    [Worker ! go || Worker <- NewWorkers],
    NewWorkers;
add_workers(More, #exec{init_runner = InitRunner, runner = {Runner, _RunnerArity}} = Exec, InitRet, NewWorkers) ->
    Control = self(),
    %% spawn all processes, and then wait until they complete InitRunner
    Worker = erlang:spawn_link(
        fun () ->
            %% need to send a message even if init_runner fails, hence 'after'
            IRR = try InitRunner(InitRet) after Control ! {self(), init_runner} end,
            receive go -> ok end,
            Runner(IRR)
        end),
    add_workers(More - 1, Exec, InitRet, [Worker | NewWorkers]).

stop_workers(Workers) ->
    %% try to stop concurrently
    [exit(Worker, kill) || Worker <- Workers],
    [receive {'EXIT', Worker, _Reason} -> ok end || Worker <- Workers].

%%%===================================================================
%%% Internal: code generation

%% @doc Creates an Erlang module (text) based on the code map passed
%%      Returns module name (may be generated), runner arity (for tracing purposes),
%%      and module source code (text)
%%      Exception: raises error with Reason = {generate, {FunName, Arity, ...}}
%%
%%      Important: early erlperf versions were generating AST (forms) instead
%%      of source code, which isn't exactly supported - AST is internal thing
%%      that can change over time.
-spec generate(code_map()) -> exec().
generate(Code) ->
    Name = list_to_atom(lists:concat(["job_", os:getpid(), "_", erlang:unique_integer([positive])])),
    generate(Name, Code).

generate(Name, #{runner := Runner} = Code) ->
    {InitFun, InitArity, InitExport, InitText} = generate_init(Name, maps:get(init, Code, error)),
    {IRFun, IRArity, IRExport, IRText} = generate_one(Name, init_runner, maps:get(init_runner, Code, error)),
    {DoneFun, DoneArity, DoneExport, DoneText} = generate_one(Name, done, maps:get(done, Code, error)),

    %% RunnerArity: how many arguments _original_ runner wants to accept.
    %% Example: run(State) is 1, and run() is 0.
    %% Pass two function names: one that is for sample_count, and one for continuous
    ContName = atom_to_list(Name),
    SampleCountName = list_to_atom(ContName ++ "_" ++ integer_to_list(erlang:unique_integer([positive]))),
    {RunnerFun, SampleRunnerFun, RunnerArity, RunArity, RunnerText} = generate_runner(Name, SampleCountName, Runner),
    RunnerExports = [{Name, RunArity}, {SampleCountName, RunArity + 1}],

    %% verify compatibility between 4 pieces of code
    %% 1. done/1 requires init/0 return value
    DoneArity =:= 1 andalso InitArity =:= undefined andalso erlang:error({generate, {done, 1, requires, init}}),
    %% 2. init_runner/1 requires init/0,1
    IRArity =:= 1 andalso InitArity =:= undefined andalso erlang:error({generate, {init_runner, 1, requires, init}}),
    %% 3. runner/1,2 requires init/0,1
    RunnerArity > 0 andalso IRArity =:= undefined andalso erlang:error({generate, {runner, RunnerArity, requires, init_runner}}),
    %% 4. runner/[3+] is not allowed
    RunnerArity > 2 andalso erlang:error({generate, {runner, RunnerArity, not_supported}}),
    %% 5. TODO: Verify there are no name clashes

    %%
    Exports = lists:concat(lists:join(", ", [io_lib:format("~s/~b", [F, Arity]) || {F, Arity} <-
        [InitExport, IRExport, DoneExport | RunnerExports], Arity =/= undefined])),

    Texts = [Text || Text <- [InitText, IRText, DoneText | RunnerText], Text =/= ""],

    Source = ["-module(" ++ atom_to_list(Name) ++ ").", "-export([" ++ Exports ++ "])." | Texts],
    #exec{name = Name, binary = compile(Name, Source), init = InitFun, init_runner = IRFun, source = Source,
        runner = {RunnerFun, RunArity}, sample_runner = {SampleRunnerFun, RunArity}, done = DoneFun}.

%% generates init/0 code
generate_init(_Mod, Fun) when is_function(Fun, 0) ->
    {Fun, 0, {[], undefined}, ""};
generate_init(_Mod, {M, F, Args}) when is_atom(M), is_atom(F), is_list(Args) ->
    {fun () -> erlang:apply(M, F, Args) end, 0, {[], undefined}, ""};
generate_init(_Mod, [{M, F, Args} | _Tail] = MFAList) when is_atom(M), is_atom(F), is_list(Args) ->
    [erlang:error({generate, {init, 0, invalid}}) ||
        {M1, F1, A} <- MFAList, not is_atom(M1) orelse not is_atom(F1) orelse not is_list(A)],
    {fun () -> [erlang:apply(M1, F1, A) || {M1, F1, A} <- MFAList] end, 0, {[], undefined}, ""};
generate_init(Mod, Text) when is_list(Text) ->
    case generate_text(init, Text, false) of
        {0, NewName, FullText} ->
            {fun () -> Mod:NewName() end, 0, {NewName, 0}, FullText};
        {WrongArity, NewName, _} ->
            erlang:error({generate, {init, NewName, WrongArity}})
    end;
generate_init(_Mod, error) ->
    {fun () -> undefined end, undefined, undefined, ""}.

%% generates init_runner/1 or done/1
generate_one(_Mod, _FunName, error) ->
    {fun (_Ignore) -> undefined end, undefined, {[], undefined}, ""};
generate_one(_Mod, _FunName, Fun) when is_function(Fun, 1) ->
    {Fun, 1, {[], undefined}, ""};
generate_one(_Mod, _FunName, Fun) when is_function(Fun, 0) ->
    {fun (_Ignore) -> Fun() end, 0, {[], undefined}, ""};
generate_one(_Mod, _FunName, {M, F, Args}) when is_atom(M), is_atom(F), is_list(Args) ->
    {fun (_Ignore) -> erlang:apply(M, F, Args) end, 0, {[], undefined}, ""};
generate_one(_Mod, FunName, [{M, F, Args} | _Tail] = MFAList) when is_atom(M), is_atom(F), is_list(Args) ->
    [erlang:error({generate, {FunName, 1, invalid, {M1, F1, A}}}) ||
        {M1, F1, A} <- MFAList, not is_atom(M1) orelse not is_atom(F1) orelse not is_list(A)],
    {fun (_Ignore) -> [erlang:apply(M1, F1, A) || {M1, F1, A} <- MFAList] end, 0, {[], undefined}, ""};
generate_one(Mod, FunName, Text) when is_list(Text) ->
    case generate_text(FunName, Text, false) of
        {0, NewName, FullText} ->
            {fun (_Ignore) -> Mod:NewName() end, 0, {NewName, 0}, FullText};
        {1, NewName, FullText} ->
            {fun (Arg) -> Mod:NewName(Arg) end, 1, {NewName, 1}, FullText};
        {WrongArity, NewName, _} ->
            erlang:error({generate, {FunName, WrongArity, NewName}})
    end.

%% runner wrapper:
%% Generates at least 2 functions, one for continuous, and one for
%%  sample-count benchmarking.
generate_runner(Mod, SampleCountName, Fun) when is_function(Fun, 0) ->
    {
        fun (_Ignore) -> Mod:Mod(Fun) end,
        fun (SampleCount, _Ignore) -> Mod:SampleCountName(SampleCount, Fun) end,
        0, 1,
        [lists:concat([Mod, "(Fun) -> Fun(), ", Mod, "(Fun)."]),
            lists:concat([SampleCountName, "(0, _Fun) -> ok; ", SampleCountName, "(Count, Fun) -> Fun(), ",
                SampleCountName, "(Count - 1, Fun)."])]
    };
generate_runner(Mod, SampleCountName, Fun) when is_function(Fun, 1) ->
    {
        fun (Init) -> Mod:Mod(Init, Fun) end,
        fun (SampleCount, Init) -> Mod:SampleCountName(SampleCount, Init, Fun) end,
        1, 2,
        [lists:concat([Mod, "(Init, Fun) -> Fun(Init), ", Mod, "(Init, Fun)."]),
            lists:concat([SampleCountName, "(0, _Init, _Fun) -> ok; ", SampleCountName, "(Count, Init, Fun) -> Fun(Init), ",
                SampleCountName, "(Count - 1, Init, Fun)."])]
    };
generate_runner(Mod, SampleCountName, Fun) when is_function(Fun, 2) ->
    {
        fun (Init) -> Mod:Mod(Init, Init, Fun) end,
        fun (SampleCount, Init) -> Mod:SampleCountName(SampleCount, Init, Init, Fun) end,
        2, 3,
        [lists:concat([Mod, "(Init, State, Fun) -> ", Mod, "(Init, Fun(Init, State), Fun)."]),
            lists:concat([SampleCountName, "(0, _Init, _State, _Fun) -> ok; ", SampleCountName, "(Count, Init, State, Fun) -> ",
                SampleCountName, "(Count - 1, Init, Fun(Init, State), Fun)."])]
    };

%% runner wrapper: MFA
generate_runner(Mod, SampleCountName, {M, F, Args}) when is_atom(M), is_atom(F), is_list(Args) ->
    {
        fun (_Ignore) -> Mod:Mod(M, F, Args) end,
        fun (SampleCount, _Ignore) -> Mod:SampleCountName(SampleCount, M, F, Args) end,
        0, 3,
        [lists:concat([Mod, "(M, F, A) -> erlang:apply(M, F, A), ", Mod, "(M, F, A)."]),
            lists:concat([SampleCountName, "(0, _M, _F, _A) -> ok; ", SampleCountName,
                "(Count, M, F, A) -> erlang:apply(M, F, A), ", SampleCountName, "(Count - 1, M, F, A)."])]
    };

%% runner wrapper: MFAList
generate_runner(Mod, SampleCountName, [{M, F, Args} | _Tail] = MFAList) when is_atom(M), is_atom(F), is_list(Args) ->
    [erlang:error({generate, {runner, 0, invalid, {M1, F1, A}}}) ||
        {M1, F1, A} <- MFAList, not is_atom(M1) orelse not is_atom(F1) orelse not is_list(A)],
    {
        fun (_Ignore) -> Mod:Mod(MFAList) end,
        fun (SampleCount, _Ignore) -> Mod:SampleCountName(SampleCount, MFAList) end,
        0, 1,
        [lists:concat([Mod, "(MFAList) -> [erlang:apply(M, F, A) || {M, F, A} <- MFAList], ", Mod, "(MFAList)."]),
            lists:concat([SampleCountName, "(0, _MFAList) -> ok; ", SampleCountName,
                "(Count, MFAList) -> [erlang:apply(M, F, A) || {M, F, A} <- MFAList], ", SampleCountName, "(Count - 1, MFAList)."])]
    };

generate_runner(Mod, SampleCountName, Text) when is_list(Text) ->
    case generate_text(runner, Text, true) of
        {0, NoDotText} ->
            %% very special case: embedding the text directly, without creating a new function
            %%  at all.
            {
                fun (_Ignore) -> Mod:Mod() end,
                fun (SampleCount, _Ignore) -> Mod:SampleCountName(SampleCount) end,
                0, 0,
                [lists:concat([Mod, "() -> ", NoDotText, ", ", Mod, "()."]),
                    lists:concat([SampleCountName, "(0) -> ok;", SampleCountName, "(Count) -> ",
                        NoDotText, ", ", SampleCountName, "(Count - 1)."]),
                    ""]
            };
        {0, NewName, FullText} ->
            {
                fun (_Ignore) -> Mod:Mod() end,
                fun (SampleCount, _Ignore) -> Mod:SampleCountName(SampleCount) end,
                0, 0,
                [lists:concat([Mod, "() -> ", NewName, "(), ", Mod, "()."]),
                    lists:concat([SampleCountName, "(0) -> ok;", SampleCountName, "(Count) -> ",
                        NewName, "(), ", SampleCountName, "(Count - 1)."]),
                    FullText]
            };
        {1, NewName, FullText} ->
            {
                fun (Init) -> Mod:Mod(Init) end,
                fun (SampleCount, Init) -> Mod:SampleCountName(SampleCount, Init) end,
                1, 1,
                [lists:concat([Mod, "(Init) -> ", NewName, "(Init), ", Mod, "(Init)."]),
                    lists:concat([SampleCountName, "(0, _Init) -> ok;", SampleCountName, "(Count, Init) -> ",
                        NewName, "(Init), ", SampleCountName, "(Count - 1, Init)."]),
                    FullText]
            };
        {2, NewName, FullText} ->
            {
                fun (Init) -> Mod:Mod(Init, Init) end,
                fun (SampleCount, Init) -> Mod:SampleCountName(SampleCount, Init, Init) end,
                2, 2,
                [lists:concat([Mod, "(Init, State) -> ", Mod, "(Init, ", NewName, "(Init, State))."]),
                    lists:concat([SampleCountName, "(0, _Init, _State) -> ok;", SampleCountName, "(Count, Init, State) -> ",
                        SampleCountName, "(Count - 1, Init, ", NewName, "(Init, State))."]),
                    FullText]
            }
    end;

generate_runner(_Mod, _SampleCountName, Any) ->
    erlang:error({generate, {parse, runner, Any}}).

%% generates function text
generate_text(Name, Text, AllowRaw) when is_list(Text) ->
    case erl_scan:string(Text) of
        {ok, Scan, _} ->
            case erl_parse:parse_form(Scan) of
                {ok, {function, _, AnyName, Arity, _}} ->
                    {Arity, AnyName, Text};
                {error, _} ->
                    % try if it's an expr
                    case erl_parse:parse_exprs(Scan) of
                        {ok, _Clauses} when AllowRaw ->
                            {0, lists:droplast(Text)};
                        {ok, _Clauses} ->
                            %% just wrap it in fun_name/0
                            {0, Name, lists:concat([Name, "() -> ", Text])};
                        {error, {_Line, ParseMod, Es}} ->
                            Errors = ParseMod:format_error(Es),
                            erlang:error({generate, {parse, Name, Errors}})
                    end
            end;
        {error, ErrorInfo, ErrorLocation} ->
            error({generate, {scan, Name, ErrorInfo, ErrorLocation}})
    end.

%% @doc Compiles text string into a binary module ready for code loading.
compile(Name, Lines) ->
    %% might not be the best way, but OTP simply does not have file:compile(Source, ...)
    %% Original design was to write the actual source file to temporary disk location,
    %%  but for diskless or write-protected hosts it was less convenient.
    Tokens = [begin {ok, T, _} = erl_scan:string(Line), T end || Line <- Lines],
    Forms = [begin {ok, F} = erl_parse:parse_form(T), F end || T <- Tokens],

    case compile:forms(Forms, [no_spawn_compiler_process, binary, return]) of
        {ok, Name, Bin} ->
            Bin;
        {ok, Name, Bin, _Warnings} ->
            Bin;
        {error, Errors, Warnings} ->
            erlang:error({compile, Errors, Warnings})
    end.
