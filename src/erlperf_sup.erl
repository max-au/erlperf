%%% @copyright (C) 2019-2023, Maxim Fedorov
%%% @doc
%%% Top-level supervisor. Always starts process group scope
%%%  for `erlperf'. Depending on the configuration starts
%%%  a number of jobs or a cluster-wide monitoring solution.
%%% @end
-module(erlperf_sup).
-author("maximfca@gmail.com").

-behaviour(supervisor).

-export([
    start_link/0,
    init/1
]).

-spec start_link() -> supervisor:startlink_ret().
start_link() ->
    supervisor:start_link({local, ?MODULE}, ?MODULE, []).

-spec init([]) -> {ok, {supervisor:sup_flags(), [supervisor:child_spec()]}}.
init([]) ->
    SupFlags = #{strategy => rest_for_one, intensity => 2, period => 60},

    ChildSpecs = [
        %% start own pg scope, needed for cluster-wide operations
        %% even if the node-wide monitoring is not running, the scope
        %% needs to be up to send "job started" events for the cluster
        #{
            id => pg,
            start => {pg, start_link, [erlperf]},
            modules => [pg]
        },

        %% monitoring
        #{
            id => erlperf_monitor,
            start => {erlperf_monitor, start_link, []},
            modules => [erlperf_monitor]
        },

        %% supervisor for statically started jobs
        #{
            id => erlperf_job_sup,
            start => {erlperf_job_sup, start_link, []},
            type => supervisor,
            modules => [erlperf_job_sup]
        }],

    {ok, {SupFlags, ChildSpecs}}.
