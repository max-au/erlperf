%%%-------------------------------------------------------------------
%%% @author Maxim Fedorov <maximfca@gmail.com>
%%% @copyright (C) 2019, Maxim Fedorov
%%%   Supervisor for all jobs running on this node.
%%% @end
%%%-------------------------------------------------------------------

-module(job_sup).

-behaviour(supervisor).

-export([
    start_job/1,
    stop_job/1,
    start_link/0,
    init/1
]).

start_link() ->
    supervisor:start_link({local, ?MODULE}, ?MODULE, []).

start_job(Code) ->
    supervisor:start_child(?MODULE, [Code]).

stop_job(Job) ->
    supervisor:terminate_child(?MODULE, Job).

init([]) ->
    {ok, {
        #{strategy => simple_one_for_one,
            intensity => 30,
            period => 60},
        [
            #{
                id => job,
                start => {job, start_link, []},
                modules => [job]
            }
        ]}}.
