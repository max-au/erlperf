%%% @copyright (C) 2019-2023, Maxim Fedorov
%%% @doc
%%% Collects, accumulates &amp; filters cluster-wide monitoring events.
%%% Essentially a simple in-memory database for quick cluster overview.
%%% Started only when the application is configured for running in a
%%% primary node.
%%% @end
-module(erlperf_history).
-author("maximfca@gmail.com").

-behaviour(gen_server).

%% API
-export([
    start_link/0,
    get/1,
    get/2
]).

%% gen_server callbacks
-export([
    init/1,
    handle_call/3,
    handle_cast/2,
    handle_info/2
]).

-define(TABLE, ?MODULE).

%%--------------------------------------------------------------------
%% @doc
%% Starts the server
-spec(start_link() ->
    {ok, Pid :: pid()} | ignore | {error, Reason :: term()}).
start_link() ->
    gen_server:start_link({local, ?MODULE}, ?MODULE, [], []).

%% @doc
%% Returns cluster history from time From (all fields), sorted
%%  by time.
-spec get(From :: integer()) -> [{node(), erlperf_monitor:monitor_sample()}].
get(From) ->
    get(From, erlang:system_time(millisecond)).

%% @doc
%% Returns records between From and To (inclusive)
%% Both From and To are Erlang system time in milliseconds.
-spec get(From :: integer(), To :: integer()) -> [{node(), erlperf_monitor:monitor_sample()}].
get(From, To) ->
    % ets:fun2ms(fun ({T, _} = R) when T =< To, T >= From -> R end =>
    %    [{{'$1','$2'},[{'=<','$1', To},{'>=','$1', From}],['$_']}]
    ets:select(?TABLE, [{{'$1','$2'},[{'=<','$1', To},{'>=','$1', From}],['$2']}]).

%%%===================================================================
%%% gen_server callbacks

% default: keep history for 120 seconds
-define(DEFAULT_HISTORY_DURATION, 120000).

% keep initial rpc timeout short
-define(RPC_TIMEOUT, 5000).

%% Keep an ordered set of samples (node, sample) ordered by time.
-record(state, {
    duration = ?DEFAULT_HISTORY_DURATION :: integer()
}).

%%%===================================================================
%%% gen_server callbacks

init([]) ->
    ok = pg:join(erlperf, cluster_monitor, self()),
    ?TABLE = ets:new(?TABLE, [protected, ordered_set, named_table]),
    {ok, #state{}}.

handle_call(_Request, _From, _State) ->
    erlang:error(notsup).

handle_cast(_Request, _State) ->
    erlang:error(notsup).

handle_info({Node, #{time := Time} = Sample}, State) ->
    ets:insert(?TABLE, {Time, {Node, Sample}}),
    {noreply, maybe_clean(State)}.

%%%===================================================================
%%% Internal functions

maybe_clean(#state{duration = Duration} =State) ->
    Expired = erlang:system_time(millisecond) - Duration,
    ets:select_delete(?TABLE, [{{'$1','$2'},[{'=<','$1', Expired}],['$_']}]),
    State.