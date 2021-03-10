%%%-------------------------------------------------------------------
%%% @author Maxim Fedorov <maximfca@gmail.com>
%%% @copyright (c) 2019 Maxim Fedorov
%%% @doc
%%%     Tests monitor
%%% @end

-module(ep_monitor_SUITE).

-include_lib("stdlib/include/assert.hrl").

-include("monitor.hrl").

%% Test server callbacks
-export([
    suite/0,
    all/0,
    init_per_suite/1, end_per_suite/1,
    init_per_testcase/2, end_per_testcase/2
]).

%% Test cases
-export([
    errors/0, errors/1,
    subscribe/0, subscribe/1
]).

suite() ->
    [{timetrap, {seconds, 10}}].

init_per_suite(Config) ->
    test_helpers:ensure_started(erlperf, Config).

end_per_suite(Config) ->
    test_helpers:ensure_stopped(Config).

init_per_testcase(_TestCase, Config) ->
    ok = ep_event_handler:subscribe(?SYSTEM_EVENT),
    Config.

end_per_testcase(_TestCase, _Config) ->
    ep_event_handler:unsubscribe(?SYSTEM_EVENT),
    ok.

all() ->
    [subscribe, errors].

%%--------------------------------------------------------------------
%% TEST CASES

subscribe() ->
    [{doc, "Tests monitoring subscription"}].

subscribe(_Config) ->
    % start a benchmark and see it running on 1 scheduler
    Code = {timer, sleep, [10]},
    {ok, Job} = ep_job:start(Code),
    ok = ep_job:set_concurrency(Job, 4),
    ?assertEqual({ok, Code, 4}, ep_job:info(Job)),
    % wait for 3 seconds, receive updates
    First = receive_updates(Job, 0, 2),
    ok = ep_job:set_concurrency(Job, 2),
    Second = receive_updates(Job, 0, 1),
    ok = gen_server:stop(Job),
    ?assert(First > 0),
    ?assert(Second > 0),
    ?assert(First > Second).

receive_updates(_, Total, 0) ->
    Total;
receive_updates(Job, Total, Count) ->
    receive
        #monitor_sample{jobs = [{Job, Cycles}]} ->
            receive_updates(Job, Total + Cycles, Count - 1);
        Other ->
            ?assertEqual([], Other)
    end.

errors() ->
    [{doc, "Test that we do not handle unknown stuff"}].

errors(_Config) ->
    ?assertException(error, badarg, ep_monitor:handle_cast(undefined, undefined)),
    ?assertException(error, badarg, ep_monitor:handle_call(undefined, self(), undefined)),
    ?assertException(error, badarg, ep_monitor:handle_info(undefined, undefined)).
