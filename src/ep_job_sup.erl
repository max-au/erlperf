%%%-------------------------------------------------------------------
%%% @author Maxim Fedorov <maximfca@gmail.com>
%%% @copyright (C) 2019, Maxim Fedorov
%%%   Supervisor for all jobs running on this node.
%%% @end
%%%-------------------------------------------------------------------

-module(ep_job_sup).

-behaviour(supervisor).

-export([
    start_link/0,
    init/1
]).

-spec start_link() -> supervisor:startlink_ret().
start_link() ->
    supervisor:start_link({local, ?MODULE}, ?MODULE, []).

-spec init([]) -> {ok, supervisor:sup_flags(), [supervisor:child_spec()]}.
init([]) ->
    {ok, {
        #{strategy => simple_one_for_one,
            intensity => 30,
            period => 60},
        [
            #{
                id => ep_job,
                start => {ep_job, start_link, []},
                modules => [ep_job]
            }
        ]}}.
