%%%-------------------------------------------------------------------
%%% @author Maxim Fedorov <maximfca@gmail.com>
%%% @copyright (C) 2019, Maxim Fedorov
%%% @doc
%%%   Collects, accumulates & filters cluster-wide metrics.
%%% @end
-module(ep_cluster_history).
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

-include_lib("erlperf/include/monitor.hrl").

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
-spec get(From :: integer()) -> [{node(), monitor_sample()}].
get(From) ->
    get(From, erlang:system_time(millisecond)).

%% @doc
%% Returns records between From and To (inclusive)
%% Both From and To are Erlang system time in milliseconds.
-spec get(From :: integer(), To :: integer()) -> [{node(), monitor_sample()}].
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

%% Suppress dialyzer warning for OTP compatibility: erlperf runs on OTP20
%%  that does not support pg, and has pg2 instead.
-dialyzer({no_missing_calls, init/1}).
-compile({nowarn_removed, [{pg2, create, 1}, {pg2, join, 2}]}).
init([]) ->
    try
        ok = pg:join(?HISTORY_PROCESS_GROUP, self())
    catch
        error:undef ->
            ok = pg2:create(?HISTORY_PROCESS_GROUP),
            ok = pg2:join(?HISTORY_PROCESS_GROUP, self())
    end,
    ?TABLE = ets:new(?TABLE, [protected, ordered_set, named_table]),
    % initial fetch (subject to race condition)
    Now = erlang:system_time(millisecond),
    From = Now - ?DEFAULT_HISTORY_DURATION,
    {Replies, _BadNodes} = gen_server:multi_call([node() | nodes()], history, {get, From, Now}, ?RPC_TIMEOUT),
    % update ETS table with all responses
    [ets:insert(?TABLE, {Time, {Node, Sample}}) || {Node, #monitor_sample{time = Time}= Sample} <- Replies],
    {ok, #state{}}.

handle_call(_Request, _From, _State) ->
    error(badarg).

handle_cast(_Request, _State) ->
    error(badarg).

handle_info({Node, #monitor_sample{time = Time} = Sample}, State) ->
    ets:insert(?TABLE, {Time, {Node, Sample}}),
    {noreply, maybe_clean(State)};

handle_info(_Info, _State) ->
    error(badarg).

%%%===================================================================
%%% Internal functions

maybe_clean(#state{duration = Duration} =State) ->
    Expired = erlang:system_time(millisecond) - Duration,
    ets:select_delete(?TABLE, [{{'$1','$2'},[{'=<','$1', Expired}],['$_']}]),
    State.