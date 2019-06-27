%%%-------------------------------------------------------------------
%%% @author Maxim Fedorov <maximfca@gmail.com>
%%% @copyright (C) 2019, Maxim Fedorov
%%% @doc
%%%   Job runner, taking care of init/done, workers added and
%%%     removed.
%%% @end
-module(ep_job).
-author("maximfca@gmail.com").

-behaviour(gen_server).

%% Job API
-export([
    start/1,
    start_link/1,
    stop/1,
    set_concurrency/2,
    info/1,
    get_counters/1,
    profile/1,
    profile/3
]).

%% gen_server callbacks
-export([
    init/1,
    handle_call/3,
    handle_cast/2,
    handle_info/2,
    terminate/2
]).

%% Job: a simple supervisor-type process. Not an actual supervisor because
%%  there is no need in fault tolerance.
%% All hooks must be defined in order for job to run.
%% Counting (atomic reference & index) are supplied externally.

%% MFArgs: module, function, arguments, or a function object.
-type mfargs() :: {module(), atom(), [term()]}.

%% Callable: one or more MFArgs, or a function object, or source code.
-type callable() :: mfargs() | [mfargs()] | fun() | fun((term()) -> term()) | string().

%% Extended "code" variant: runner code, setup/teardown hooks, additional parameters
%%  used to save/load job.
-type code_map() :: #{
    runner := callable(),
    init => callable(),
    init_runner => callable(),
    done  => callable(),
    %
    initial_concurrency => non_neg_integer(),
    name => string()
}.

%% Code: callable, callable with hooks
-type code() :: callable() | code_map().

%%--------------------------------------------------------------------
%% @doc
%% Starts the benchmark instance using default (ep_job_sup) supervisor.
-spec start(code()) -> {ok, Pid :: pid()} | {error, {already_started, pid()}} | {error, Reason :: term()}.
start(Code) when is_map(Code); tuple_size(Code) =:= 3; is_function(Code); is_list(Code) ->
    supervisor:start_child(ep_job_sup, [Code]).

%% @doc
%% Starts the benchmark instance and links it to caller.
%% Job starts with no workers, use set_concurrency/2 to start some.
-spec start_link(code()) -> {ok, Pid :: pid()} | {error, {already_started, pid()}} | {error, Reason :: term()}.
start_link(Code) when is_map(Code); tuple_size(Code) =:= 3; is_function(Code); is_list(Code) ->
    gen_server:start_link(?MODULE, Code, []).

%% @doc
%% Stops the benchmark instance (via supervisor).
-spec stop(pid()) -> ok.
stop(JobId) ->
    supervisor:terminate_child(ep_job_sup, JobId).

%% @doc
%% Change concurrency setting for this job.
%% Does not reset counting.
-spec set_concurrency(pid(), non_neg_integer()) -> ok.
set_concurrency(JobId, Concurrency) ->
    gen_server:call(JobId, {set_concurrency, Concurrency}).

%% @doc
%% Returns information about currently running job. Includes job description,
%%  and number of currently running workers.
-spec info(pid()) -> {ok, code(), Concurrency :: non_neg_integer()}.
info(JobId) ->
    gen_server:call(JobId, info).

%% @doc
%% Internally used by the monitoring process to access job atomic counter.
-spec get_counters(pid()) -> reference().
get_counters(JobId) ->
    gen_server:call(JobId, get_counters).

%% @doc
%% Runs a single iteration, using fprof profiler
-spec profile(pid()) -> term().
profile(JobId) ->
    profile(JobId, fprof, term).

%% @doc
%% Runs a profiler for a selected number of runner iterations.
-spec profile(pid(), fprof, term | binary | string) -> term().
profile(JobId, Profiler, Format) ->
    profile_impl(gen_server:call(JobId, get_code), Profiler, Format).

%%--------------------------------------------------------------------
%% Internal definitions

-include_lib("kernel/include/logger.hrl").

-include("monitor.hrl").

-record(state, {
    % original spec
    code :: code(),
    % MFAs for all used/compiled functions
    init :: callable(),
    done :: callable(),
    init_runner :: callable(),
    runner :: callable(),
    % code:delete() this module when terminating
    module = [] :: module() | [],
    %
    init_result :: term(),
    init_runner_result :: term(),
    %
    workers = [] :: [pid()],
    % counter reference (index is always 1)
    cref :: reference()
}).


%%%===================================================================
%%% gen_server callbacks

init(Code) ->
    CRef = atomics:new(1, []),
    State0 = maybe_compile(Code),
    IR = call(State0#state.init, undefined),
    erlang:process_flag(trap_exit, true),
    gen_event:notify(?JOB_EVENT, {started, self(), Code, CRef}),
    State1 = State0#state{code = Code, cref = CRef, init_result = IR},
    maybe_save(Code),
    Concurrency = if is_map(Code) -> maps:get(initial_concurrency, Code, 0); true -> 0 end,
    {ok, State1#state{
        workers = set_concurrency_impl(Concurrency, State1)
    }}.

handle_call(info, _From, #state{code = Code} = State) ->
    {reply, {ok, Code, length(State#state.workers)}, State};

handle_call(get_counters, _From, #state{cref = CRef} = State) ->
    {reply, CRef, State};

handle_call({set_concurrency, Concurrency}, _From, State) ->
    {reply, ok, State#state{workers = set_concurrency_impl(Concurrency, State)}};

handle_call(get_code, _From, #state{runner = Runner, init_runner = IR, init_result = IRR} = State) ->
    {reply, {Runner, IR, IRR}, State};

handle_call(_Request, _From, _State) ->
    error(badarg).

handle_cast(_Request, _State) ->
    error(badarg).

handle_info({'EXIT', Worker, Reason}, State) when Reason =:= shutdown; Reason =:= normal ->
    {noreply, State#state{workers = lists:delete(Worker, State#state.workers)}};
handle_info({'EXIT', Worker, Reason}, _State) ->
    ?LOG_ERROR("Worker ~p crashed with ~100p", [Worker, Reason]),
    {stop, Reason};

handle_info(_Info, _State) ->
    error(badarg).

terminate(_Reason, #state{done = Done, init_result = IR, module = Mod} = State) ->
    % terminate all workers first
    set_concurrency_impl(0, State),
    call(Done, IR),
    if Mod =/= [] ->
        _ = code:purge(Mod),
        true = code:delete(Mod),
        _ = code:purge(Mod),
        true = code:delete(Mod);
        true ->
            ok
    end.

%%%===================================================================
%%% Internal: callable & runner implementation
%%%===================================================================

maybe_save(#{name := Name} = Code) ->
    Filename = filename:join(code:priv_dir(erlperf), Name),
    filelib:ensure_dir(Filename),
    file:write_file(Filename, term_to_binary(Code));
maybe_save(_) ->
    ok.

%% undefined: return undefined
call(undefined, _) ->
    undefined;

%% Simple case: MFArgs, potentially +1 argument
call({M, F, A}, Arg) when is_atom(M), is_atom(F), is_list(A) ->
    case erlang:function_exported(M, F, length(A)) of
        true ->
            erlang:apply(M, F, A);
        false ->
            erlang:apply(M, F, A ++ [Arg])
    end;

%% MFA List (+1 argument always ignored)
call([{M, F, A}], _) when is_atom(M), is_atom(F), is_list(A) ->
    erlang:apply(M, F, A);
call([{M, F, A} | Tail], _) when is_atom(M), is_atom(F), is_list(A) ->
    erlang:apply(M, F, A),
    call(Tail, undefined);

%% function object
call(Fun, _) when is_function(Fun, 0) ->
    Fun();
call(Fun, Arg) when is_function(Fun, 1) ->
    Fun(Arg).

%% Different runners (optimisation, could've used call/2 for it, but - benchmarking!)
runner(M, F, A, CRef) ->
    erlang:apply(M, F, A),
    atomics:add(CRef, 1, 1),
    runner(M, F, A, CRef).

runner_list(List, CRef) ->
    _ = [erlang:apply(M, F, A) || {M, F, A} <- List],
    atomics:add(CRef, 1, 1),
    runner_list(List, CRef).

runner_fun_0(Fun, CRef) ->
    Fun(),
    atomics:add(CRef, 1, 1),
    runner_fun_0(Fun, CRef).

runner_fun_1(Fun, IWR, CRef) ->
    Fun(IWR),
    atomics:add(CRef, 1, 1),
    runner_fun_1(Fun, IWR, CRef).

%% necessary optimisation: remove as much as possible from the actual loop
runner_impl({M, F, A}, IWR, CRef) ->
    case erlang:function_exported(M, F, length(A)) of
        true ->
            runner(M, F, A, CRef);
        false ->
            runner(M, F, A ++ [IWR], CRef)
    end;
% for [MFA], init/init_runner are not applicable
runner_impl([{_, _, _} | _] = List, _IWR, CRef) ->
    runner_list(List, CRef);
% for fun() with 0 args, init/init_runner are not applicable
runner_impl(Fun, _IWR, CRef) when is_function(Fun, 0) ->
    runner_fun_0(Fun, CRef);
% clause for fun(Arg).
runner_impl(Fun, IWR, CRef) when is_function(Fun, 1) ->
    runner_fun_1(Fun, IWR, CRef).

set_concurrency_impl(Concurrency, #state{workers = Workers}) when length(Workers) =:= Concurrency ->
    Workers;

set_concurrency_impl(Concurrency, #state{workers = Workers, init_runner = InitRunner, init_result = IR,
    runner = Runner, cref = CRef})
    when length(Workers) < Concurrency ->
    Hired = [spawn_link(
        fun () -> runner_impl(Runner, call(InitRunner, IR), CRef) end)
        || _ <- lists:seq(length(Workers) + 1, Concurrency)],
    Workers ++ Hired;

set_concurrency_impl(Concurrency, #state{workers = Workers}) ->
    {Remaining, ToFire} =
        if Concurrency > 0 ->
                lists:split(Concurrency, Workers);
            true ->
                {[], Workers}
        end,
    [exit(Pid, shutdown) || Pid <- ToFire],
    % monitors procs die
    wait_for_killed(ToFire),
    %
    Remaining.

wait_for_killed([]) ->
    ok;
wait_for_killed([Pid | Tail]) ->
    receive
        {'EXIT', Pid, _} ->
            wait_for_killed(Tail)
    end.

%%%===================================================================
%%% Compilation primitives
%%%===================================================================

-define(IS_SOURCE(Text), is_list(Text), not is_tuple(hd(Text)), not is_function(hd(Text))).

ensure_loaded({M, _, _} = MFA) when is_atom(M) ->
    case code:ensure_loaded(M) of
        {module, M} ->
            MFA;
        {error, nofile} ->
            error({module_not_found, M})
    end;
ensure_loaded([]) ->
    error("empty callable");
ensure_loaded({[]}) ->
    error("empty callable");
ensure_loaded(Other) when ?IS_SOURCE(Other) ->
    error("cannot mix source and non-source forms");
ensure_loaded(Other) ->
    Other.

%% Converts a text form into Erlang Abstract Form,
%%  and returns function name.
-spec export(atom(), string()) -> {atom(), non_neg_integer(), string()}.
export(DefaultName, Text) ->
    {ok, Scan, _} = erl_scan:string(Text),
    case erl_parse:parse_form(Scan) of
        {ok, {function, _, Name, Arity, _} = Form} ->
            {Name, Arity, Form};
        {error, _} ->
            % try if it's an expr
            case erl_parse:parse_exprs(Scan) of
                {ok, Clauses} ->
                    Form = {function, 1, DefaultName, 0,
                        [{clause,1,[],[], Clauses}]},
                    {DefaultName, 0, Form};
                Error ->
                    error(Error)
            end
    end.

try_export(Name, Map) when is_map_key(Name, Map) ->
    export(Name, maps:get(Name, Map));
try_export(_, _) ->
    undefined.

ensure_callable(_Mod, undefined) ->
    undefined;
ensure_callable(Mod, {Name, _, _}) ->
    {Mod, Name, []}.

module_name() ->
    list_to_atom(lists:flatten(io_lib:format("job_~p_~p", [node(), self()]))).

maybe_compile(#{runner := Runner} = Code) ->
    maybe_compile(Runner, maps:remove(runner, Code));

maybe_compile(Code) when not is_map(Code) ->
    maybe_compile(Code, #{}).

maybe_compile(Text, Hooks) when ?IS_SOURCE(Text) ->
    %
    Mod = module_name(),
    %
    ModForm = {attribute, 1, module, Mod},
    % form source code
    {RunnerName, _, _} = Runner = export(runner, Text),
    % init/done
    Init = try_export(init, Hooks),
    Done = try_export(done, Hooks),
    InitRunner = try_export(init_runner, Hooks),
    %
    Forms = [Runner, Init, InitRunner, Done],
    %
    ExportForm = {attribute,1,export,[{Name, Arity} || {Name, Arity, _} <- Forms]},
    %
    AllForms = [ModForm, ExportForm | [Form || {_, _, Form} <- Forms]],
    %
    % ct:pal("Code: ~tp", [AllForms]),
    %
    {ok, App, Bin} = compile:forms(AllForms),
    {module, Mod} = code:load_binary(App, atom_to_list(Mod), Bin),
    #state{
        module = Mod,
        runner = {Mod, RunnerName, []},
        init = ensure_callable(Mod, Init),
        done = ensure_callable(Mod, Done),
        init_runner = ensure_callable(Mod, InitRunner)
    };

%% No compilation required
maybe_compile(Runner, Hooks) ->
    #state{
        runner = ensure_loaded(Runner),
        init = ensure_loaded(maps:get(init, Hooks, undefined)),
        init_runner = ensure_loaded(maps:get(init_runner, Hooks, undefined)),
        done = ensure_loaded(maps:get(done, Hooks, undefined))
    }.

%%%===================================================================
%%% Profiling support

profile_impl({Runner, InitRunner, InitResult}, fprof, Format) ->
    run_fprof(Runner, InitRunner, InitResult, Format).

ensure_fprof_started({ok, _Pid}) ->
    ok;
ensure_fprof_started({error, {already_started, _Pid}}) ->
    ok;
ensure_fprof_started(Error) ->
    Error.

run_fprof(Runner, InitRunner, InitResult, Format) ->
    ok = ensure_fprof_started(fprof:start()),
    IRR = call(InitRunner, InitResult),
    case Runner of
        {M, F, A} ->
            case erlang:function_exported(M, F, length(A)) of
                true ->
                    fprof:apply(M, F, A);
                false ->
                    fprof:apply(M, F, A ++ [IRR])
            end;
        List when is_list(List) ->
            fprof:trace(start),
            _ = [erlang:apply(M, F, A) || {M, F, A} <- List],
            fprof:trace(stop);
        Fun when is_function(Fun, 0) ->
            fprof:apply(Fun, []);
        Fun when is_function(Fun) ->
            fprof:apply(Fun, [IRR])
    end,
    ok = fprof:profile(),
    % don't use file-base output, generate an Erlang structure
    % TODO: this is quite a weird way, consult a text output...
    TypeWriter = proc_lib:spawn_link(fun () -> capture_io([]) end),
    ok = fprof:analyse([{dest, TypeWriter}]),
    TypeWriter ! {read, self()},
    receive
        {result, Result} ->
            process_fprof_result(Result, Format)
    after 5000 ->
        error(timeout)
    end.

process_fprof_result(Io, term) ->
    {_, Terms} =
        lists:foldl(
            fun (S, {Cont, Acc}) ->
                List = binary_to_list(S),
                case erl_scan:tokens(Cont, List, 1, []) of
                    {more, Cont1} ->
                        {Cont1, Acc};
                    {done, Term, LeftOver} ->
                        {more, Cont1} = erl_scan:tokens([], LeftOver, 1, []),
                        {ok, Term1, _} = Term,
                        {ok, Term2} = erl_parse:parse_term(Term1),
                        {Cont1, [Term2 | Acc]}
                end
            end, {[], []}, Io),
    lists:reverse(Terms);
process_fprof_result(Io, string) ->
    [binary_to_list(S) || S <- Io];
process_fprof_result(Io, binary) ->
    Io.

capture_io(Io) ->
    receive
        {io_request, From, Me, {put_chars, _Encoding, Binary}} ->
            From ! {io_reply, Me, ok},
            capture_io([iolist_to_binary(Binary) | Io]);
        {io_request, From, Me, {put_chars, _Encoding, M, F, A}} ->
            From ! {io_reply, Me, ok},
            capture_io([iolist_to_binary(apply(M,F, A)) | Io]);
        {read, WhereTo} ->
            WhereTo ! {result, lists:reverse(Io)};
        _Other ->
            capture_io(Io)
    end.
