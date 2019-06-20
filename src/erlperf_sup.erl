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

-include("monitor.hrl").

-define(SERVER, ?MODULE).

start_link() ->
    supervisor:start_link({local, ?SERVER}, ?MODULE, []).

init([]) ->
    SupFlags = #{strategy => rest_for_one,
                 intensity => 2,
                 period => 60},
    ChildSpecs = [
        % event bus for job-related changes, started-stopped jobs
        #{id => ?JOB_EVENT,
            start => {gen_event, start_link, [{local, ?JOB_EVENT}]},
            modules => dynamic},

        % supervisor for all concurrently running jobs
        #{id => ep_job_sup,
            start => {ep_job_sup, start_link, []},
            type => supervisor,
            modules => [ep_job_sup]},

        % supervisor for node & cluster monitoring
        #{id => ep_monitor_sup,
            start => {ep_monitor_sup, start_link, []},
            type => supervisor,
            modules => [ep_monitor_sup]}
        ],
    {ok, {SupFlags, ChildSpecs}}.
