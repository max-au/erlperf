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
    init/1
]).

-include("monitor.hrl").

-define(SERVER, ?MODULE).

start_link() ->
    case application:get_env(start_monitor) of
        {ok, false} ->
            ignore;
        _ ->
            supervisor:start_link({local, ?SERVER}, ?MODULE, [])
    end.

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

        %% file log, if asked for
        #{id => ep_file_log,
            start => {ep_file_log, start_link, []},
            modules => [ep_file_log]},

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
            modules => [ep_monitor]}
        ],
    {ok, {SupFlags, ChildSpecs}}.
