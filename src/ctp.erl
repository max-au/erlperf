%%%-------------------------------------------------------------------
%%% @author dane
%%% @copyright (C) 2018, <COMPANY>
%%% @doc
%%%
%%% @end
%%% Created : 10. Dec 2018 09:16
%%%-------------------------------------------------------------------
-module(ctp).
-author("dane").

-behaviour(gen_server).

%% API

-export([
    start_trace/1,
    start_trace/2,
    stop_trace/0,
    analyse/0,
    analyse/1,
    run/2,
    run/5
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
    area = local :: local | global, %% see erlang:trace_pattern() for details about local/global
    data = []:: [{module(), [{{Fun :: atom(), non_neg_integer()}, Count :: non_neg_integer(),Time :: non_neg_integer()}]}], % {ets, [{internal_select_delete,2,1,1}, {internal_delete_all,2,3,4}]}
    traced_procs :: term()
}).

%%%===================================================================
%%% API
%%%===================================================================
start_trace(PidPortSpec) ->
    start_trace(PidPortSpec, #{}).

start_trace(PidPortSpec, Options0) ->
    Options = maps:merge(#{area => local}, Options0),
    gen_server:call(?MODULE, {start_trace, PidPortSpec, Options}, infinity).

stop_trace() ->
    gen_server:call(?MODULE, stop_trace, infinity).

analyse() ->
    analyse(#{}).

analyse(Options0) ->
    Options = maps:merge(#{sort => none, format => callgrind, progress => undefined}, Options0),
    gen_server:call(?MODULE, {analyse, Options}, infinity).

run(PidPortSpec, TimeMs) ->
    run(PidPortSpec, TimeMs, #{}, #{}, "/tmp/callgrind.001").

run(PidPortSpec, TimeMs, TraceOptions, AnalysisOptions, Filename) ->
    % see if server was started
    NotRunning = whereis(?MODULE) =:= undefined,
    NotRunning andalso start(),
    %
    start_trace(PidPortSpec, TraceOptions),
    receive after TimeMs -> ok end, % this is just sleep(TimeMs)
    ctp:stop_trace(),
    %
    {ok, Trace} = analyse(AnalysisOptions),
    is_list(Filename) andalso (catch file:write_file(Filename, Trace)),
    NotRunning andalso stop(),
    ok.

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

handle_call({start_trace, PidPortSpec, #{area := Area}}, _From, #state{tracing = false} = State) ->
    trace_pattern(true, Area),
    erlang:trace(PidPortSpec, true, [call, arity, silent]),
    {reply, ok, State#state{tracing = true, traced_procs = PidPortSpec, area = Area}};
handle_call({start_trace, _PidPortSpec}, _From, #state{tracing = true} = State) ->
    {reply, {error, already_started}, State};

handle_call(stop_trace, _From, #state{tracing = true, traced_procs = PidPortSpec, area = Area} = State) ->
    trace_pattern(pause, Area),
    erlang:trace(PidPortSpec, false, [call]),
    {reply, ok, State#state{tracing = false}};
handle_call(stop_trace, _From, #state{tracing = false} = State) ->
    {reply, {error, not_started}, State};

handle_call({analyse, _}, _From, #state{tracing = true} = State) ->
    {reply, {error, tracing}, State};
handle_call({analyse, #{format := Format, sort := SortBy, progress := Progress}}, _From,
    #state{tracing = false, area = Area} = State) ->
    % collect all functions & their execution time
    {ok, Data} = pmap([{'$system', undefined} | code:all_loaded()], fun trace_time/1, {Progress, trace_info}, infinity),
    %
    trace_pattern(false, Area),
    %
    Formatted = format_analysis(Data, {Progress, export}, Format, SortBy),
    {reply, {ok, Formatted}, State#state{data = Data}};

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
handle_info(_Info, State) ->
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
%%% Internal functions
%%%===================================================================

trace_pattern(Action, global) ->
    trace_pattern_impl(Action, [call_time]);
trace_pattern(Action, local) ->
    trace_pattern_impl(Action, [local, call_time]).

trace_pattern_impl(Action, Flags) ->
    % erlang:system_flag(multi_scheduling, block), % while this seems to be correct, it stops the node and lets it die
    erlang:trace_pattern({'_', '_', '_'}, Action, Flags),
    % erlang:system_flag(multi_scheduling, unblock), % node is dead by now
    ok.

pmap(List, Fun, Message, Timeout) ->
    Parent = self(),
    Workers = [spawn_monitor(fun() ->
        process_flag(priority, low),
        Parent ! {self(), Fun(Item), element(1, case is_list(Item) of true -> hd(Item); _ -> Item end)}
                             end) || Item <- List],
    gather(Workers, {Message, 0, length(List), undefined}, Timeout, []).

gather([], _Progress, _Timeout, Acc) ->
    {ok, Acc};
gather(Workers, {Message, Done, Total, PrState} = Progress, Timeout, Acc) ->
    receive
        {Pid, Res, Name} when is_pid(Pid) ->
            case lists:keytake(Pid, 1, Workers) of
                {value, {Pid, MRef}, NewWorkers} ->
                    erlang:demonitor(MRef, [flush]),
                    NewPrState = report_progress(Message, Name, Done + 1, Total, PrState),
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

trace_time({'$system', _}) ->
    Map = lists:foldl(fun ({M, F, A}, Acc) ->
        maps:update_with(M, fun (L) -> [{F, A} | L] end, [], Acc)
                      end, #{}, erlang:system_info(snifs)),
    SysMods = maps:map(fun(Mod, Funs) ->
        lists:filtermap(fun ({F, A}) ->
            collate_mfa(F, A, erlang:trace_info({Mod, F, A}, call_time))
                        end, Funs)
                       end, Map),
    maps:to_list(SysMods);
trace_time({Mod, _}) ->
    [{Mod, lists:filtermap(fun ({F, A}) ->
        collate_mfa(F, A, erlang:trace_info({Mod, F, A}, call_time))
                    end, Mod:module_info(functions))}].

collate_mfa(F, A, {call_time, List}) when is_list(List) ->
    {Cnt, Clock} = lists:foldl(fun ({_, C, S, U}, {Cnt, Us}) ->
        {Cnt + C, Us + U + S * 1000000}
                end, {0, 0}, List),
    {true, {F, A, Cnt, Clock}};
collate_mfa(_, _, _) ->
    false.

% Sorting support
expand_mods(Data) ->
    List = lists:append(Data),
    lists:append([[{Mod, F, A, C, T} || {F, A, C, T} <- Funs] || {Mod, Funs} <- List]).

sort_column(call_time) -> 5;
sort_column(call_count) -> 4;
sort_column(module) -> 1;
sort_column('fun') -> 2.

format_analysis(Data, _Progress, none, none) ->
    lists:append(Data);
format_analysis(Data, _Progress, none, Order) ->
    lists:append([lists:reverse(lists:keysort(sort_column(Order), expand_mods(Data)))]);

format_analysis(Data, _Progress, text, none) ->
    io_lib:format("~p", [lists:append(Data)]);
format_analysis(Data, _Progress, text, Order) ->
    io_lib:format("~p", [lists:reverse(lists:keysort(sort_column(Order), expand_mods(Data)))]);

format_analysis(Data, Progress, callgrind, _) ->
    % prepare data in parallel
    {ok, Lines} = pmap(Data, fun format_callgrind/1, Progress, infinity),
    % concatenate binaries
    merge_binaries(Lines, <<"# callgrind format\nevents: CallTime Calls\n">>).

merge_binaries([], Binary) ->
    Binary;
merge_binaries([H|T], Binary) ->
    merge_binaries(T, <<Binary/binary, 10:8, H/binary>>).

format_callgrind(ModList) ->
    lists:foldl(fun ({Mod, Funs}, Acc) ->
        Mt = atom_to_binary(Mod, latin1),
        NextAcc = <<Acc/binary, <<"fl=">>/binary, Mt/binary, 10:8>>,
        lists:foldl(fun ({F, A, C, T}, Bin) ->
            Ft = atom_to_binary(F, latin1),
            At = integer_to_binary(A),
            Ct = integer_to_binary(C),
            Ut = integer_to_binary(T),
            <<Bin/binary, <<"fn={">>/binary, Ft/binary, $,, At/binary, <<"}\n1 ">>/binary, Ut/binary, $ , Ct/binary, 10:8>>
                    end, NextAcc, Funs)
                end, <<>>, ModList).

report_progress({Progress, Message}, Module, Done, Total, PrState) when is_function(Progress, 5) ->
    Progress(Message, Module, Done, Total, PrState);
report_progress({Progress, Message}, Module, Done, Total, PrState) when is_pid(Progress) ->
    Progress ! {Message, Module, Done, Total, PrState};

% default progress printer
report_progress({undefined, _}, _, Done, Done, _) ->
    io:format(group_leader(), " complete.~n", []),
    undefined;
report_progress({undefined, Info}, _, _, Total, undefined) ->
    io:format(group_leader(), "~-20s started: ", [Info]),
    Total div 10;
report_progress({undefined, _}, _Module, Done, Total, Next) when Done > Next ->
    io:format(group_leader(), " ~b% ", [Done * 100 div Total]),
    Done + (Total div 10);
report_progress(_, _, _, _, PrState) ->
    PrState.
