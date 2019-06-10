%%%-------------------------------------------------------------------
%%% @author Maxim Fedorov <maximfca@gmail.com>
%%% @copyright (C) 2019, Maxim Fedorov
%%% @doc
%%%   Saves benchmarks for future use (database).
%%% @end
-module(benchmark_store).
-author("maximfca@gmail.com").

%% API

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

%%%===================================================================
%%% Persistence API - NIY

-record(erlperf_callable, {
    id :: integer(),
    code :: job:callable()
}).

-record(erlperf_benchmark, {
    id :: integer(),
    name = [] :: string(),
    description = [] :: string(),
    runner,
    init,
    init_runner,
    done
}).

-record(erlperf_result, {
    id :: integer(),
    benchmark,
    start,
    finish,
    system_info,
    throughput
}).

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

handle_info(_Info, _State) ->
    error(badarg).

%%%===================================================================
%%% Internal functions
