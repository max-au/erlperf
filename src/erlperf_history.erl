%%% @copyright (C) 2019-2023, Maxim Fedorov
%%% @doc
%%% Collects, accumulates &amp; filters cluster-wide monitoring events.
%%% Essentially a simple in-memory database for quick cluster overview.
%%%
%%% History server helps to collect monitoring reports from multiple
%%% nodes of a single Erlang cluster. Example setup: single primary
%%% node running `erlperf_history' and {@link erlperf_cluster_monitor}
%%% listens to reports sent by several more nodes in a cluster, running
%%% continuous benchmarking jobs. Nodes may run the same Erlang code,
%%% but using different hardware or OS version. Or, conversely, same
%%% hardware and OS, but variants of Erlang code. See {@link erlperf_cluster_monitor}
%%% for a code sample.
%%%
%%%
%%% @end
-module(erlperf_history).
-author("maximfca@gmail.com").

-behaviour(gen_server).

%% API
-export([
    start_link/0,
    start_link/1,
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

%% default: keep history for 120 seconds
-define(DEFAULT_HISTORY_DURATION, 120000).

%% @equiv start_link(120_000)
-spec(start_link() ->
    {ok, Pid :: pid()} | ignore | {error, Reason :: term()}).
start_link() ->
    start_link(?DEFAULT_HISTORY_DURATION).

%% @doc
%% Starts the history server and links it to the calling process.
%%
%% Designed for use as a part of a supervision tree.
%% `Duration' is time (in milliseconds), how long to keep the
%% reports for. Older reports are discarded.
-spec(start_link(Duration :: pos_integer()) ->
    {ok, Pid :: pid()} | ignore | {error, Reason :: term()}).
start_link(Duration) ->
    gen_server:start_link({local, ?MODULE}, ?MODULE, [Duration], []).

%% @doc
%% Returns cluster history.
%%
%% Returns all reports since `From' timestamp to now, sorted by timestamp.
%% `From' is wall clock time, in milliseconds (e.g. `os:system_time(millisecond)').
-spec get(From :: integer()) -> [{Time :: non_neg_integer(), erlperf_monitor:monitor_sample()}].
get(From) ->
    get(From, os:system_time(millisecond)).

%% @doc
%% Returns cluster history reports between From and To (inclusive).
%%
%% `From' and `To' are wall clock time, in milliseconds (e.g. `os:system_time(millisecond)').
-spec get(From :: integer(), To :: integer()) -> [{Time :: non_neg_integer(), erlperf_monitor:monitor_sample()}].
get(From, To) ->
    % ets:fun2ms(fun ({{T, _}, _} = R) when T =< To, T >= From -> {T, R} end).
    ets:select(?TABLE, [{{{'$1', '_'}, '$2'},[{'=<', '$1', To}, {'>=', '$1', From}], [{{'$1', '$2'}}]}]).

%%===================================================================
%% gen_server implementation

%% Keep an ordered set of samples (node, sample) ordered by time.
-record(state, {
    duration :: pos_integer()
}).

%% @private
init([Duration]) ->
    ok = pg:join(erlperf, cluster_monitor, self()),
    ?TABLE = ets:new(?TABLE, [protected, ordered_set, named_table, {write_concurrency, true}]),
    {ok, #state{duration = Duration}}.

%% @private
handle_call(_Request, _From, _State) ->
    erlang:error(notsup).

%% @private
handle_cast(_Request, _State) ->
    erlang:error(notsup).

%% @private
handle_info(#{time := Time, node := Node} = Sample, State) ->
    ets:insert(?TABLE, {{Time, Node}, Sample}),
    {noreply, maybe_clean(State)}.

%% ===================================================================
%% Internal functions

maybe_clean(#state{duration = Duration} =State) ->
    Expired = os:system_time(millisecond) - Duration,
    %% ets:fun2ms(fun ({{T, _}, _}) -> T =< Expired end).
    ets:select_delete(?TABLE, [{{{'$1', '_'},'_'},[{'=<','$1', Expired}],[true]}]),
    State.