%%%-------------------------------------------------------------------
%%% @author Maxim Fedorov <maximfca@gmail.com>
%%% @copyright (c) 2019-2023 Maxim Fedorov
%%% @doc
%%%     Tests monitor
%%% @end

-module(erlperf_monitor_SUITE).

-include_lib("stdlib/include/assert.hrl").

%% Test server callbacks
-export([
    suite/0,
    all/0
]).

%% Test cases
-export([
    subscribe/0, subscribe/1
]).

suite() ->
    [{timetrap, {seconds, 10}}].

all() ->
    [subscribe].

%%--------------------------------------------------------------------
%% TEST CASES

subscribe() ->
    [{doc, "Tests monitoring subscription"}].

subscribe(_Config) ->
    {ok, Mon} = erlperf_sup:start_link(), %% instead of starting the app
    ok = pg:join(erlperf, {erlperf_monitor, node()}, self()),
    % start a benchmark and see it running on 1 scheduler
    {ok, Job} = erlperf_job:start_link(#{runner => {timer, sleep, [10]}}),
    ok = erlperf_job:set_concurrency(Job, 4),
    ?assertEqual(4, erlperf_job:concurrency(Job)),
    % wait for 3 seconds, receive updates
    First = receive_updates(Job, 0, 2),
    ok = erlperf_job:set_concurrency(Job, 2),
    Second = receive_updates(Job, 0, 1),
    ok = gen_server:stop(Job),
    ?assert(First > 0),
    ?assert(Second > 0),
    ?assert(First > Second),
    pg:leave(erlperf, {erlperf_monitor, node()}, self()),
    gen:stop(Mon).

receive_updates(_, Total, 0) ->
    Total;
receive_updates(Job, Total, Count) ->
    receive
        #{jobs := [{Job, Cycles}]} ->
            receive_updates(Job, Total + Cycles, Count - 1);
        Other ->
            ?assertEqual([], Other)
    end.
