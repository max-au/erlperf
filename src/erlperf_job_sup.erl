%%% @copyright (C) 2019-2023, Maxim Fedorov
%%% Supervises statically started jobs.
%%% @end
-module(erlperf_job_sup).
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
    {ok, {
        #{strategy => simple_one_for_one,
            intensity => 30,
            period => 60},
        [
            #{
                id => erlperf_job,
                start => {erlperf_job, start_link, []},
                modules => [erlperf_job]
            }
        ]}}.
