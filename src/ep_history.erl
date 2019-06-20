%%%-------------------------------------------------------------------
%%% @author Maxim Fedorov <maximfca@gmail.com>
%%% @copyright (C) 2019, Maxim Fedorov
%%% @doc
%%%   Saves monitor history.
%%% @end
-module(ep_history).
-author("maximfca@gmail.com").

-behaviour(gen_server).

%% API
-export([
    start_link/0,
    get/1,
    get/2,
    get_last/1
]).

%% gen_server callbacks
-export([
    init/1,
    handle_call/3,
    handle_cast/2,
    handle_info/2,
    terminate/2
]).


-include("monitor.hrl").

-define(SERVER, ?MODULE).

% default: keep history for 120 seconds
-define(DEFAULT_HISTORY_DURATION, 120000).

%%--------------------------------------------------------------------
%% @doc
%% Starts the server
-spec(start_link() ->
    {ok, Pid :: pid()} | ignore | {error, Reason :: term()}).
start_link() ->
    gen_server:start_link({local, ?SERVER}, ?MODULE, [], []).


%% @doc
%% Returns records starting from From (until now).
-spec get(integer()) -> [].
get(From) ->
    get(From, erlang:system_time(millisecond)).

%% @doc
%% Returns records between From and To (inclusive)
%% Both From and To are Erlang system time in milliseconds.
-spec get(integer(), integer()) -> [].
get(From, To) ->
    gen_server:call(?SERVER, {get, From, To}).

%% @doc
%% Returns records for last N seconds.
-spec get_last(N :: integer()) -> [].
get_last(N) ->
    Now = erlang:system_time(millisecond),
    get(Now - N * 1000, Now).

%%%===================================================================
%%% gen_server callbacks

%% System monitor state
-record(state, {
    history :: queue:queue(),
    duration = ?DEFAULT_HISTORY_DURATION
}).

%% gen_server init
init([]) ->
    % subscribe to monitor events
    ep_event_handler:subscribe(?SYSTEM_EVENT),
    % for unsubscription - gen_event does not do it automatically
    erlang:process_flag(trap_exit, true),
    {ok, #state{history = queue:new()}}.

handle_call({get, From, To}, _From, #state{history = History} = State) ->
    {reply, [Sample || Sample = #monitor_sample{time = Time} <- queue:to_list(History), Time >= From, Time =< To], State};

handle_call(_Request, _From, _State) ->
    error(badarg).

handle_cast(_Request, _State) ->
    error(badarg).

handle_info(#monitor_sample{} = Sample, #state{history = History, duration = Duration} = State) ->
    {noreply, State#state{history = clean_history(queue:in(Sample, History), erlang:system_time(millisecond) - Duration)}};

handle_info(_Info, _State) ->
    error(badarg).

terminate(_Reason, _State) ->
    ep_event_handler:unsubscribe(?SYSTEM_EVENT).

%%%===================================================================
%%% Internal functions

clean_history(Queue, Cutoff) ->
    case queue:out(Queue) of
        {{value, #monitor_sample{time = Time}}, Remain} when Time < Cutoff ->
            clean_history(Remain, Time);
        _ ->
            Queue
    end.
