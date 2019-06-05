%%%-------------------------------------------------------------------
%%% @author Maxim Fedorov <maximfca@gmail.com>
%%% @copyright (C) 2019, Maxim Fedorov
%%% @doc
%%%   Saves monitor history.
%%% @end
-module(history).
-author("maximfca@gmail.com").

-behaviour(gen_server).

%% API
-export([
    start_link/0,
    get/1
]).

%% gen_server callbacks
-export([
    init/1,
    handle_call/3,
    handle_cast/2,
    handle_info/2
]).


-include("monitor.hrl").

-define(SERVER, ?MODULE).

% default: keep 120 last samples (seconds)
-define(DEFAULT_HISTORY_LENGTH, 60).

%%--------------------------------------------------------------------
%% @doc
%% Starts the server
-spec(start_link() ->
    {ok, Pid :: pid()} | ignore | {error, Reason :: term()}).
start_link() ->
    gen_server:start_link({local, ?SERVER}, ?MODULE, [], []).

%% @doc
%% Returns last N samples
-spec get(non_neg_integer()) -> [].
get(Samples) ->
    gen_server:call(?SERVER, {get, Samples}).

%%%===================================================================
%%% gen_server callbacks

%% System monitor state
-record(state, {
    % history cache (may be logged to file, DETS table, mnesia etc.)
    history :: queue:queue(),
    % current queue length
    length = 0 :: non_neg_integer(),
    % maximum queue length
    max_length = ?DEFAULT_HISTORY_LENGTH
}).

%% gen_server init
init([]) ->
    % subscribe to monitor events
    event_handler:subscribe(system_event),
    {ok, #state{history = queue:new()}}.

handle_call({get, Samples}, _From, #state{length = Len, history = History} = State) when Samples >= Len ->
    {reply, queue:to_list(History), State};
handle_call({get, Samples}, _From, #state{length = Len, history = History} = State) ->
    {_, Data} = queue:split(Len - Samples, History),
    {reply, queue:to_list(Data), State};

handle_call(_Request, _From, _State) ->
    error(badarg).

handle_cast(_Request, _State) ->
    error(badarg).

handle_info(#monitor_sample{} = Sample, #state{length = Len, max_length = MaxLen, history = History} = State) when Len >= MaxLen ->
    handle_info(Sample,
        State#state{length = Len - 1, max_length = MaxLen, history = queue:drop(History)});

handle_info(#monitor_sample{} = Sample, #state{length = Len, history = History} = State) ->
    {noreply, State#state{history = queue:in(Sample, History), length = Len + 1}};

handle_info(_Info, _State) ->
    error(badarg).

%%%===================================================================
%%% Internal functions
