%%%-------------------------------------------------------------------
%%% @author Maxim Fedorov <maximfca@gmail.com>
%%% @copyright (c) 2019 Maxim Fedorov
%%% @doc
%%%     Tests monitor
%%% @end

-module(monitor_SUITE).

%% Common Test headers
-include_lib("common_test/include/ct.hrl").
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
    subscribe/0, subscribe/1
]).

suite() ->
    [{timetrap, {seconds, 10}}].

init_per_suite(Config) ->
    {ok, Apps} = application:ensure_all_started(erlperf),
    [{apps, Apps} | Config].

end_per_suite(Config) ->
    [application:stop(App) || App <- ?config(apps, Config)],
    ok.

init_per_testcase(_TestCase, Config) ->
    ok = event_handler:subscribe(system_event),
    Config.

end_per_testcase(_TestCase, _Config) ->
    event_handler:unsubscribe(system_event),
    ok.

all() ->
    [subscribe].

%%--------------------------------------------------------------------
%% TEST CASES

subscribe() ->
    [{doc, "Tests monitoring subscription + getting history"}].

subscribe(_Config) ->
    history:get(20),
    % start a benchmark and see it running on 1 scheduler
    {ok, Job} = job:start_link({timer, sleep, [10]}),
    [{Job, _Index, UID}] = monitor:which_jobs(),
    ok = job:set_concurrency(Job, 1),
    % wait for 3 seconds, receive updates
    Total = receive_updates(UID, 0, 3),
    ok = gen_server:stop(Job),
    ?assert(Total > 0).

receive_updates(_, Total, 0) ->
    Total;
receive_updates(ID, Total, Count) ->
    receive
        #monitor_sample{jobs = [{ID, Cycles}]} ->
            receive_updates(ID, Total + Cycles, Count - 1);
        Other ->
            ?assertEqual([], Other)
    end.
