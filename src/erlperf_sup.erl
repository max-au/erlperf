%%%-------------------------------------------------------------------
%%% @author Maxim Fedorov <maximfca@gmail.com>
%%% @copyright (C) 2019, Maxim Fedorov
%%% @doc
%%%     Top-level supervisor, spawns job supervisor and monitor.
%%% @end
%%%-------------------------------------------------------------------

-module(erlperf_sup).

-behaviour(supervisor).

-export([
    start_link/0,
    init/1
]).

-define(SERVER, ?MODULE).

start_link() ->
    supervisor:start_link({local, ?SERVER}, ?MODULE, []).

init([]) ->
    SupFlags = #{strategy => rest_for_one,
                 intensity => 5,
                 period => 120},
    Optional = case application:get_env(file_log) of
                   {ok, Filename} when is_list(Filename) ->
                       [
                           %% file log, if asked for
                           #{id => file_log,
                               start => {file_log, start_link, [Filename]},
                               modules => [file_log]}
                       ];
                   _ ->
                       []
               end,
    ChildSpecs = [
        % event bus for applications willing to receive monitoring updates
        % suffers from all traditional gen_event problems
        #{id => system_event,
            start => {gen_event, start_link, [{local, system_event}]},
            modules => dynamic},
        % system monitor: collects all jobs statistical data to
        %   fire events, depends on event but to be alive
        #{id => monitor,
            start => {monitor, start_link, []},
            modules => [monitor]},
        %% history collection
        #{id => history,
            start => {history, start_link, []},
            modules => [history]},
        % supervisor for all concurrently running jobs. Uses atomics
        %   supplied by monitor
        #{id => job_sup,
            start => {job_sup, start_link, []},
            type => supervisor,
            modules => [job_sup]}
    ],
    {ok, {SupFlags, ChildSpecs ++ Optional}}.
