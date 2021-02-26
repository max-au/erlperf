%%%-------------------------------------------------------------------
%%% @author Maxim Fedorov <maximfca@gmail.com>
%%% @copyright (C) 2019, Maxim Fedorov
%%% @doc
%%%   Forwards monitoring events to process group.
%%%     It's technically possible to avoid using gen_server,
%%%     and simply do everything in gen_event handler, but this
%%%     does not play well with supervision.
%%% @end
-module(ep_monitor_proxy).
-author("maximfca@gmail.com").

-behaviour(gen_server).

%% API
-export([
    start_link/0
]).

%% gen_server callbacks
-export([
    init/1,
    handle_call/3,
    handle_cast/2,
    handle_info/2
]).

-include("monitor.hrl").

%%--------------------------------------------------------------------
%% @doc
%% Starts the server
-spec(start_link() ->
    {ok, Pid :: pid()} | ignore | {error, Reason :: term()}).
start_link() ->
    gen_server:start_link({local, ?MODULE}, ?MODULE, [], []).


%%%===================================================================
%%% gen_server callbacks

%% Cluster logger state
-record(state, {
}).

-type state() :: #state{}.

%% gen_server init
%% Suppress dialyzer warning for OTP compatibility: erlperf runs on OTP20
%%  that does not support pg, and has pg2 instead.
-dialyzer({no_missing_calls, init/1}).
-compile({nowarn_removed, [{pg2, create, 1}, {pg2, get_members, 1}]}).
-spec init([]) -> {ok, state()}.
init([]) ->
    catch pg2:create(?HISTORY_PROCESS_GROUP), %% don't care if it fails, and it does on OTP 24
    ep_event_handler:subscribe(?SYSTEM_EVENT),
    {ok, #state{}}.

handle_call(_Request, _From, _State) ->
    error(badarg).

-spec handle_cast(term(), state()) -> no_return().
handle_cast(_Request, _State) ->
    error(badarg).

-dialyzer({no_missing_calls, handle_info/2}).
handle_info(#monitor_sample{} = Sample, State) ->
    Monitors =
        try pg:get_members(?HISTORY_PROCESS_GROUP)
        catch error:undef -> pg2:get_members(?HISTORY_PROCESS_GROUP)
    end,
    [Pid ! {node(), Sample} || Pid <- Monitors],
    {noreply, State};

handle_info(_Info, _State) ->
    error(badarg).

%%%===================================================================
%%% Internal functions
