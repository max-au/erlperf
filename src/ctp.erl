%%%-------------------------------------------------------------------
%%% @author Maxim Fedorov <maxim@photokid.com.au>
%%% @copyright Maxim Fedorov
%%% @doc
%%%
%%% @end
%%% Created : 10. Dec 2018 09:16
%%%-------------------------------------------------------------------
-module(ctp).
-author("dane").

-behaviour(gen_server).

%% Simple (immediate) API
-export([
    time/1,
    time/4,
    trace/1,
    trace/4,
    sample/4,
    replay/1,
    export_callgrind/2
]).

%% gen_server API
-export([
    start_trace/0,
    start_trace/1,
    stop_trace/0,
    collect/0,
    collect/1,
    format/0,
    format/1
]).

%% Generic start/stop API
-export([
    start/0,
    start_link/0,
    stop/0,
    stop/1]).

%% gen_server callbacks
-export([init/1,
    handle_call/3,
    handle_cast/2,
    handle_info/2,
    terminate/2,
    code_change/3]).

-record(state, {
    tracing = false :: boolean(),
    tracer = undefined :: undefined | pid(),
    call_time = undefined :: undefined | [{module(), [{{Fun :: atom(), non_neg_integer()},
        Count :: non_neg_integer(), Time :: non_neg_integer()}]}], % {ets, [{internal_select_delete,2,1,1}, {internal_delete_all,2,3,4}]}
    samples = undefined :: undefined | [term()],
    traced_procs :: term()
}).

%%%===================================================================
%%% API

time(TimeMs) ->
    time(all, TimeMs, [{'_', '_', '_'}], silent).

time(PidPortSpec, TimeMs, MFAList, Progress) when is_list(MFAList), tuple_size(hd(MFAList)) =:= 3 ->
    [erlang:trace_pattern(MFA, true, [local, call_time]) || MFA <- MFAList],
    erlang:trace(PidPortSpec, true, [silent, call]),
    receive after TimeMs -> ok end,
    erlang:trace(PidPortSpec, false, [call]),
    Data = collect_impl(undefined, Progress),
    erlang:trace_pattern({'_', '_', '_'}, false, [local, call_time]),
    process_callers(Data, #{}).

trace(TimeMs) ->
    trace(all, TimeMs, [{'_', '_', '_'}], silent).

trace(PidPortSpec, TimeMs, MFAList, Progress) ->
    TracerPid = spawn(fun tracer/0),
    TraceSpec = [{'_', [], [{message, {{cp, {caller}}}}]}],
    [erlang:trace_pattern(MFA, TraceSpec, [local, call_time]) || MFA <- MFAList],
    erlang:trace(PidPortSpec, true, [arity, call, {tracer, TracerPid}]),
    receive after TimeMs -> ok end,
    erlang:trace(PidPortSpec, false, [call]),
    Data = collect_impl(TracerPid, Progress),
    erlang:trace_pattern({'_', '_', '_'}, false, [local, call_time]),
    {Counts, #{}} = fetch_trace(TracerPid, Progress, infinity),
    Callers = collect_callers(Counts),
    process_callers(Data, Callers).

sample(PidPortSpec, TimeMs, MFAList, Progress) when is_list(MFAList), tuple_size(hd(MFAList)) =:= 3 ->
    TracerPid = spawn(fun tracer/0),
    TraceSpec = [{'_', [], [{message, {{cp, {caller}}}}]}],
    [erlang:trace_pattern(MFA, TraceSpec, [local]) || MFA <- MFAList],
    erlang:trace(PidPortSpec, true, [call, {tracer, TracerPid}]),
    receive after TimeMs -> ok end,
    erlang:trace(PidPortSpec, false, [call]),
    {[], Samples} = fetch_trace(TracerPid, Progress, infinity),
    Samples.

replay(Filename) when is_list(Filename) ->
    {ok, Bin} = file:read_file(Filename),
    Map = binary_to_term(Bin),
    true = is_map(Map),
    replay(Map);
replay(Map) when is_map(Map) ->
    Calls = lists:append(maps:values(Map)),
    timer:tc(lists:foreach(fun ({M,F,A}) -> erlang:apply(M,F,A) end, Calls)).

export_callgrind(Data, Filename) ->
    % build a large iolist, write it down
    Lines = lists:map(fun ({Mod, Funs}) ->
        [io_lib:format("fl=~s\n", [Mod]), lists:map(fun ({F,A,C,Us,Calls}) ->
            Called = [io_lib:format("cfl=~s\ncfn=~s:~b\ncalls=~b 1\n1 1 1\n", [CM, CF, CA, CC]) || {CM,CF,CA,CC} <- Calls],
            io_lib:format("fn=~s/~b\n1 ~b ~b\n", [F,A,Us,C]) ++ Called;
            ({F,A,C,Us}) ->
                io_lib:format("fn=~s/~b\n1 ~b ~b\n", [F,A,Us,C])
                                                    end, Funs)]
                      end, Data),
    Binary = iolist_to_binary([<<"# callgrind format\nevents: CallTime Calls\n\n">> | Lines]),
    file:write_file(Filename, Binary),
    Binary.

%%%===================================================================
%%% gen_server API
%%%===================================================================
start_trace() ->
    start_trace(#{}).

start_trace(Options0) ->
    Options = maps:merge(#{spec => all, sample => none, arity => true}, Options0),
    gen_server:call(?MODULE, {start_trace, Options}, infinity).

stop_trace() ->
    gen_server:call(?MODULE, stop_trace, infinity).

collect() ->
    collect(#{}).

collect(Options0) ->
    Options = maps:merge(#{progress => undefined}, Options0),
    gen_server:call(?MODULE, {collect, Options}, infinity).

format() ->
    format(#{}).

format(Options0) ->
    Options = maps:merge(#{sort => none, format => callgrind, progress => undefined}, Options0),
    gen_server:call(?MODULE, {format, Options}, infinity).

%%%===================================================================
%%% Generic start/stop API
%%%===================================================================

%%--------------------------------------------------------------------
%% @doc
%% Starts call tracing profiler as a standalone server
%%
%% @end
%%--------------------------------------------------------------------
-spec(start() ->
    {ok, Pid :: pid()} | ignore | {error, Reason :: term()}).
start() ->
    gen_server:start({local, ?MODULE}, ?MODULE, [], []).


%%--------------------------------------------------------------------
%% @doc
%% Starts call tracing profiler as a part of supervision tree
%%
%% @end
%%--------------------------------------------------------------------
-spec(start_link() ->
    {ok, Pid :: pid()} | ignore | {error, Reason :: term()}).
start_link() ->
    gen_server:start_link({local, ?MODULE}, ?MODULE, [], []).

%%--------------------------------------------------------------------
%% @doc
%% Stops call tracing profiler
%%
%% @end
%%--------------------------------------------------------------------
stop()  ->
    stop(infinity).

-spec(stop(Timeout :: integer() | infinity) -> ok).
stop(Timeout)  ->
    gen_server:stop(?MODULE, shutdown, Timeout).

%%%===================================================================
%%% gen_server callbacks
%%%===================================================================

%%--------------------------------------------------------------------
%% @private
%% @doc
%% Initializes the server
%%
%% @spec init(Args) -> {ok, State} |
%%                     {ok, State, Timeout} |
%%                     ignore |
%%                     {stop, Reason}
%% @end
%%--------------------------------------------------------------------
-spec(init(Args :: term()) ->
    {ok, State :: #state{}} | {ok, State :: #state{}, timeout() | hibernate} |
    {stop, Reason :: term()} | ignore).
init([]) ->
    {ok, #state{}}.

%%--------------------------------------------------------------------
%% @private
%% @doc
%% Handling call messages
%%
%% @end
%%--------------------------------------------------------------------
-spec(handle_call(Request :: term(), From :: {pid(), Tag :: term()},
    State :: #state{}) ->
    {reply, Reply :: term(), NewState :: #state{}} |
    {reply, Reply :: term(), NewState :: #state{}, timeout() | hibernate} |
    {noreply, NewState :: #state{}} |
    {noreply, NewState :: #state{}, timeout() | hibernate} |
    {stop, Reason :: term(), Reply :: term(), NewState :: #state{}} |
    {stop, Reason :: term(), NewState :: #state{}}).

handle_call({start_trace, #{spec := PidPortSpec, sample := Sample, arity := Arity0}}, _From, #state{tracing = false} = State) ->
    % trace call_time for all
    erlang:trace_pattern({'_', '_', '_'}, true, [local, call_time]),
    %
    Tracer = case Sample of
        [_|_] ->
            % trace selected MFAs
            Arity = case Arity0 of true -> [arity]; _ -> [] end,
            {TracerPid, _} = spawn_monitor(fun tracer/0),
            TraceSpec = [{'_', [], [{message, {{cp, {caller}}}}]}],
            [erlang:trace_pattern(MFA, TraceSpec, [local]) || MFA <- Sample],
            erlang:trace(PidPortSpec, true, [call, {tracer, TracerPid}] ++ Arity),
            TracerPid;
        _ ->
            erlang:trace(PidPortSpec, true, [silent, call]),
            undefined
    end,
    {reply, ok, State#state{tracing = true, traced_procs = PidPortSpec, tracer = Tracer}};

handle_call({start_trace, _PidPortSpec, _}, _From, #state{tracing = true} = State) ->
    {reply, {error, already_started}, State};

handle_call(stop_trace, _From, #state{tracing = true, traced_procs = PidPortSpec} = State) ->
    erlang:trace(PidPortSpec, false, [call]),
    erlang:trace_pattern({'_', '_', '_'}, pause, [local, call_time]),
    {reply, ok, State#state{tracing = false}};

handle_call(stop_trace, _From, #state{tracing = false} = State) ->
    {reply, {error, not_started}, State};

handle_call({collect, _}, _From, #state{tracing = true} = State) ->
    {reply, {error, tracing}, State};

handle_call({collect, #{progress := Progress}}, _From, #state{tracing = false, tracer = Tracer} = State) ->
    Data = collect_impl(Tracer, Progress),
    erlang:trace_pattern({'_', '_', '_'}, false, [local, call_time]),
    % request data from tracer (ask for Progress too!)
    Samples = fetch_trace(Tracer, Progress, infinity),
    %
    {reply, ok, State#state{call_time = Data, samples = Samples}};

handle_call({format, _}, _From, #state{tracing = true} = State) ->
    {reply, {error, tracing}, State};
handle_call({format, _}, _From, #state{call_time = undefined} = State) ->
    {reply, {error, no_trace}, State};

% no sampling/tracing done
handle_call({format, #{format := Format, sort := SortBy, progress := Progress}}, _From,
    #state{tracing = false, call_time = Data, samples = undefined} = State) ->
    {reply, {ok, format_analysis(Data, #{}, {Progress, export}, Format, SortBy)}, State};

% include tracing
handle_call({format, #{format := Format, sort := SortBy, progress := Progress}}, _From,
    #state{tracing = false, call_time = Data, samples = {Count, Trace}} = State) ->
    Callers = collect_callers(Count),
    {reply, {ok, format_analysis(Data, Callers, {Progress, export}, Format, SortBy), Trace}, State};


handle_call(Request, _From, State) ->
    {reply, {error, {unexpected, Request}}, State}.

%%--------------------------------------------------------------------
%% @private
%% @doc
%% Handling cast messages
%%
%% @end
%%--------------------------------------------------------------------
-spec(handle_cast(Request :: term(), State :: #state{}) ->
    {noreply, NewState :: #state{}} |
    {noreply, NewState :: #state{}, timeout() | hibernate} |
    {stop, Reason :: term(), NewState :: #state{}}).
handle_cast(_Request, State) ->
    {noreply, State}.

%%--------------------------------------------------------------------
%% @private
%% @doc
%% Handling all non call/cast messages
%%
%% @spec handle_info(Info, State) -> {noreply, State} |
%%                                   {noreply, State, Timeout} |
%%                                   {stop, Reason, State}
%% @end
%%--------------------------------------------------------------------
-spec(handle_info(Info :: timeout() | term(), State :: #state{}) ->
    {noreply, NewState :: #state{}} |
    {noreply, NewState :: #state{}, timeout() | hibernate} |
    {stop, Reason :: term(), NewState :: #state{}}).

handle_info({'DOWN',_MRef,process,Pid,normal}, #state{tracer = Pid, tracing = false} = State) ->
    {noreply, State#state{tracer = undefined}};

handle_info(Info, State) ->
    io:format("unexpected info: ~p~n", [Info]),
    {noreply, State}.

%%--------------------------------------------------------------------
%% @private
%% @doc
%% This function is called by a gen_server when it is about to
%% terminate. It should be the opposite of Module:init/1 and do any
%% necessary cleaning up. When it returns, the gen_server terminates
%% with Reason. The return value is ignored.
%%
%% @spec terminate(Reason, State) -> void()
%% @end
%%--------------------------------------------------------------------
-spec(terminate(Reason :: (normal | shutdown | {shutdown, term()} | term()),
    State :: #state{}) -> term()).
terminate(_Reason, #state{tracing = true, traced_procs = PidPortSpec}) ->
    erlang:trace(PidPortSpec, false, [call]);
terminate(_Reason, _State) ->
    ok.

%%--------------------------------------------------------------------
%% @private
%% @doc
%% Convert process state when code is changed
%%
%% @spec code_change(OldVsn, State, Extra) -> {ok, NewState}
%% @end
%%--------------------------------------------------------------------
-spec(code_change(OldVsn :: term() | {down, term()}, State :: #state{},
    Extra :: term()) ->
    {ok, NewState :: #state{}} | {error, Reason :: term()}).
code_change(_OldVsn, State, _Extra) ->
    {ok, State}.

%%%===================================================================
%%% Tracer process. Discards PIDs, either collects ETS table
%%  with {{M, F, Arity, Caller}, Count}, or a map {Caller, [{M, F, Args}]} for
%%  extended tracing.
tracer() ->
    process_flag(message_queue_data, off_heap),
    TracerTab = ets:new(tracer, [set, private]), % table destroys itself after exiting process
    tracer_loop(TracerTab, #{}).

tracer_loop(Tab, Data) ->
    receive
        {trace, _Pid, call, {M, F, Arity}, {cp, Caller}} when is_integer(Arity) ->
            ets:update_counter(Tab, {M, F, Arity, Caller}, 1, {{M, F, Arity, Caller}, 1}),
            tracer_loop(Tab, Data);
        {trace, _Pid, call, MFA, {cp, Caller}} ->
            Data1 = maps:update_with(Caller, fun (L) -> [MFA|L] end, [MFA], Data),
            tracer_loop(Tab, Data1);
        {data, Control} ->
            Control ! {data, ets:tab2list(Tab), Data},
            ets:delete_all_objects(Tab),
            tracer_loop(Tab, []);
        stop ->
            ok;
        _ ->
            % maybe count something wrong happening?
            tracer_loop(Tab, Data)
    end.

%%%===================================================================
%%% Internal functions
%%%===================================================================

pmap(List, Extra, Fun, Message, Timeout) ->
    Parent = self(),
    Workers = [spawn_monitor(fun() ->
        Parent ! {self(), Fun(Item, Extra)}
                             end) || Item <- List],
    gather(Workers, {Message, 0, length(List), undefined}, Timeout, []).

gather([], _Progress, _Timeout, Acc) ->
    {ok, Acc};
gather(Workers, {Message, Done, Total, PrState} = Progress, Timeout, Acc) ->
    receive
        {Pid, Res} when is_pid(Pid) ->
            case lists:keytake(Pid, 1, Workers) of
                {value, {Pid, MRef}, NewWorkers} ->
                    erlang:demonitor(MRef, [flush]),
                    NewPrState = report_progress(Message, Done + 1, Total, PrState),
                    gather(NewWorkers, {Message, Done + 1, Total, NewPrState}, Timeout, [Res | Acc]);
                false ->
                    gather(Workers, Progress, Timeout, Acc)
            end;
        {'DOWN', MRef, process, Pid, Reason} ->
            case lists:keyfind(Pid, 1, Workers) of
                {Pid, MRef} ->
                    % stop collecting results, as they're broken anyway, exit all spawned procs
                    [exit(P, kill) || {P, _MRef} <- Workers],
                    {error, Reason};
                false ->
                    gather(Workers, Progress, Timeout, Acc)
            end
    after Timeout ->
        timeout
    end.

collect_impl(Tracer, Progress) ->
    {ok, Data} = pmap(
        [{'$system', undefined} | code:all_loaded()],
        Tracer,
        fun trace_time/2,
        {Progress, trace_info},
        infinity),
    Data.

trace_time({'$system', _}, Tracer) ->
    Map = lists:foldl(fun ({M, F, A}, Acc) ->
        maps:update_with(M, fun (L) -> [{F, A} | L] end, [], Acc)
                      end, #{}, erlang:system_info(snifs)),
    SysMods = maps:map(fun(Mod, Funs) ->
        lists:filtermap(fun ({F, A}) ->
            collate_mfa(F, A, erlang:trace_info({Mod, F, A}, call_time), Tracer)
                        end, Funs)
                       end, Map),
    maps:to_list(SysMods);
trace_time({Mod, _}, Tracer) ->
    [{Mod, lists:filtermap(fun ({F, A}) ->
        collate_mfa(F, A, erlang:trace_info({Mod, F, A}, call_time), Tracer)
                           end, Mod:module_info(functions))}].

collate_mfa(F, A, {call_time, List}, Tracer) when is_list(List) ->
    {Cnt, Clock} = lists:foldl(
        fun ({Pid, _, _, _}, Acc) when Tracer =:= Pid ->
                Acc;
            ({_, C, S, U}, {Cnt, Us}) ->
                {Cnt + C, Us + U + S * 1000000}
        end, {0, 0}, List),
    {true, {F, A, Cnt, Clock}};
collate_mfa(_, _, _, _) ->
    false.

% Sorting support
expand_mods(Data) ->
    List = lists:append(Data),
    lists:append([[{Mod, F, A, C, T} || {F, A, C, T} <- Funs] || {Mod, Funs} <- List]).

sort_column(call_time) -> 5;
sort_column(call_count) -> 4;
sort_column(module) -> 1;
sort_column('fun') -> 2.

% [{M,F,A,Caller,Count}]
collect_callers(Counts) ->
    lists:foldl(fun ({{M,F,A,Caller},Count}, Map) ->
        maps:update_with(Caller, fun (L) ->
            [{M,F,A,Count} | L]
                                 end, [{M,F,A,Count}], Map)
                end, #{}, Counts).

format_analysis(Data, _, _Progress, none, none) ->
    lists:append(Data);
format_analysis(Data, _, _Progress, none, Order) ->
    lists:append([lists:reverse(lists:keysort(sort_column(Order), expand_mods(Data)))]);

format_analysis(Data, _, _Progress, text, none) ->
    io_lib:format("~p", [lists:append(Data)]);
format_analysis(Data, _, _Progress, text, Order) ->
    io_lib:format("~p", [lists:reverse(lists:keysort(sort_column(Order), expand_mods(Data)))]);

format_analysis(Data, CountMap, Progress, callgrind, _) ->
    % prepare data in parallel
    {ok, Lines} = pmap(Data, CountMap, fun format_callgrind/2, Progress, infinity),
    % concatenate binaries
    merge_binaries(Lines, <<"# callgrind format\nevents: CallTime Calls\n">>).

merge_binaries([], Binary) ->
    Binary;
merge_binaries([H|T], Binary) ->
    merge_binaries(T, <<Binary/binary, 10:8, H/binary>>).

format_callgrind_line({Mod, Funs}, {Count, Acc}) ->
    Mt = atom_to_binary(Mod, latin1),
    NextAcc = <<Acc/binary, <<"fl=">>/binary, Mt/binary, 10:8>>,
    {Count, lists:foldl(fun ({F, A, C, T}, Bin) ->
        Ft = atom_to_binary(F, latin1),
        At = integer_to_binary(A),
        Ct = integer_to_binary(C),
        Ut = integer_to_binary(T),
        NoCallsLine = <<Bin/binary, <<"fn={">>/binary, Ft/binary, $,, At/binary,
            <<"}\n1 ">>/binary, Ut/binary, $ , Ct/binary, 10:8>>,
        case maps:get({Mod, F, A}, Count, undefined) of
            undefined ->
                NoCallsLine;
            Callees when is_list(Callees) ->
                lists:foldl(fun ({CM, CF, CA, CC}, CallAcc) ->
                    CMt = atom_to_binary(CM, latin1),
                    CFt = atom_to_binary(CF, latin1),
                    CAt = integer_to_binary(CA),
                    CCt = integer_to_binary(CC),
                    <<CallAcc/binary, <<"cfi=">>/binary, CMt/binary,
                        <<"\ncfn={">>/binary, CFt/binary, $,, CAt/binary,
                        <<"}\ncalls=">>/binary, CCt/binary, <<" 1\n1 1 1\n">>/binary>>
                            end, NoCallsLine, Callees)
        end
                end, NextAcc, Funs)}.

format_callgrind(ModList, Count) ->
    element(2, lists:foldl(fun format_callgrind_line/2, {Count, <<>>}, ModList)).

report_progress({Progress, Message}, Done, Total, PrState) when is_function(Progress, 4) ->
    Progress(Message, Done, Total, PrState);
report_progress({Progress, Message}, Done, Total, PrState) when is_pid(Progress) ->
    Progress ! {Message, Done, Total, PrState};

% silent progress printer
report_progress({silent, _}, _, _, State) ->
    State;
% default progress printer
report_progress({undefined, _}, Done, Done, _) ->
    io:format(group_leader(), " complete.~n", []),
    undefined;
report_progress({undefined, Info}, _, Total, undefined) ->
    io:format(group_leader(), "~-20s started: ", [Info]),
    Total div 10;
report_progress({undefined, _}, Done, Total, Next) when Done > Next ->
    io:format(group_leader(), " ~b% ", [Done * 100 div Total]),
    Done + (Total div 10);
report_progress(_, _, _, PrState) ->
    PrState.

tracer_qlen(Pid) ->
    case erlang:process_info(Pid, message_queue_len) of
        {message_queue_len, QLen} -> QLen;
        _ -> 0
    end.

wait_for_data(_, Progress, PrState, QDone, QTotal, Timeout) when Timeout =< 0 ->
    report_progress(Progress, QDone, QTotal, PrState),
    timeout;
wait_for_data(TracerPid, Progress, PrState, QDone, QTotal, Timeout) ->
    receive
        {data, Count, Trace} ->
            report_progress(Progress, QDone, QDone, PrState),
            {Count, Trace}
        after 1000 ->
            NewQTotal = tracer_qlen(TracerPid),
            NewQDone = QDone + (QTotal - NewQTotal), % yes it can go backwards, but that means tracing is still on
            NewPrState = report_progress(Progress, NewQDone, NewQTotal, PrState),
            wait_for_data(TracerPid, Progress, NewPrState, NewQDone, NewQTotal,
                if is_integer(Timeout) -> Timeout - 1000; true -> infinity end)
    end.

fetch_trace(TracerPid, Progress, Timeout) when is_pid(TracerPid) ->
    TracerPid ! {data, self()},
    TracerPid ! stop,
    wait_for_data(TracerPid, Progress, undefined, 0, tracer_qlen(TracerPid), Timeout);
fetch_trace(_, _, _) ->
    undefined.


% collate: Data [{Module, [Fun,Arity,Count,Sec,Usec]}] === {erl_prim_loader,[{debug,2,0,0},
%   and -> {M,F,Arity} => {M,F,Arity,Count} === #{{ctp,trace,4} => [{erlang,trace,3,2}],
process_callers(Data, Callers) ->
    lists:filtermap(fun ({Mod, Funs}) ->
        case lists:filtermap(
            fun ({_,_,0,0}) ->
                false;
                ({F,Arity,C,Us}) ->
                    {true, {F,Arity,C,Us,maps:get({Mod,F,Arity}, Callers, [])}}
            end, Funs) of
            [] -> false;
            Other -> {true, {Mod, Other}}
        end
                    end, lists:append(Data)).
