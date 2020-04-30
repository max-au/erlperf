%%%-------------------------------------------------------------------
%%% @author Maxim Fedorov <maximfca@gmail.com>
%%% @copyright (C) 2019, Maxim Fedorov
%%% @doc
%%% Monitoring supervisor. Does not start when application is
%%%   running in embedded mode.
%%% @end
%%%-------------------------------------------------------------------

-module(ep_monitor_sup).

-behaviour(supervisor).

-export([
    start_link/0,
    start_link/2,
    init/1
]).

-include("monitor.hrl").

-spec start_link() -> supervisor:startlink_ret().
start_link() ->
    case application:get_env(start_monitor) of
        {ok, false} ->
            ignore;
        _ ->
            supervisor:start_link({local, ?MODULE}, ?MODULE, [])
    end.

-spec start_link(RegName :: atom(), LogTo :: ep_file_log | ep_cluster_monitor) -> supervisor:startlink_ret().
start_link(Sup, Log) ->
    supervisor:start_link({local, Sup}, ?MODULE, Log).

-spec init(ep_file_log | ep_cluster_monitor | []) -> {ok, {supervisor:sup_flags(), [supervisor:child_spec()]}}.
init(Log) when Log =:= ep_file_log; Log =:= ep_cluster_monitor ->
    SupFlags = #{
        strategy => simple_one_for_one,
        intensity => 5,
        period => 60},
    ChildSpecs = [
        #{id => Log,
            start => {Log, start_link, []},
            modules => [Log]}
    ],
    {ok, {SupFlags, ChildSpecs}};

init([]) ->
    SupFlags = #{strategy => rest_for_one,
                 intensity => 5,
                 period => 60},
    ChildSpecs = [
        % event bus for applications willing to receive monitoring updates
        % suffers from all traditional gen_event problems
        #{id => ?SYSTEM_EVENT,
            start => {gen_event, start_link, [{local, ?SYSTEM_EVENT}]},
            modules => dynamic},

        %% history collection
        #{id => ep_history,
            start => {ep_history, start_link, []},
            modules => [ep_history]},

        %% pg2 logger
        #{id => ep_monitor_proxy,
            start => {ep_monitor_proxy, start_link, []},
            modules => [ep_monitor_proxy]},

        %% entire cluster monitoring
        #{id => ep_cluster_history,
            start => {ep_cluster_history, start_link, []},
            modules => [ep_cluster_history]},

        % system monitor: collects all jobs statistical data to
        %   fire events, depends on system_event to be alive
        #{id => ep_monitor,
            start => {ep_monitor, start_link, []},
            modules => [ep_monitor]},

        % file/console node-only monitor
        #{id => ep_file_log_sup,
            start => {?MODULE, start_link, [ep_file_log_sup, ep_file_log]},
            type => supervisor,
            modules => [?MODULE]},

        % cluster-wide monitoring
        #{id => ep_cluster_monitor_sup,
            start => {?MODULE, start_link, [ep_cluster_monitor_sup, ep_cluster_monitor]},
            type => supervisor,
            modules => [?MODULE]}

        ],
    {ok, {SupFlags, ChildSpecs}}.
