%%%-------------------------------------------------------------------
%%% @author Maxim Fedorov <maximfca@gmail.com>
%%% @copyright (c) 2019 Maxim Fedorov
%%% @doc
%%%     Tests monitor
%%% @end

-module(ep_history_SUITE).

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
    get_last/0, get_last/1
]).

suite() ->
    [{timetrap, {seconds, 10}}].

init_per_suite(Config) ->
    test_helpers:ensure_started(erlperf, Config).

end_per_suite(Config) ->
    test_helpers:ensure_stopped(Config).

init_per_testcase(_TestCase, Config) ->
    Config.

end_per_testcase(_TestCase, _Config) ->
    ok.

all() ->
    [errors, get_last].

%%--------------------------------------------------------------------
%% TEST CASES

errors() ->
    [{doc, "Test that we do not handle unknown stuff"}].

errors(_Config) ->
    ?assertException(error, badarg, ep_history:handle_cast(undefined, undefined)),
    ?assertException(error, badarg, ep_history:handle_call(undefined, self(), undefined)),
    ?assertException(error, badarg, ep_history:handle_info(undefined, undefined)),
    % piggy-backing: not a good idea, but adding entire test suite for monitor_pg2_proxy is overkill
    ?assertException(error, badarg, ep_monitor_proxy:handle_cast(undefined, undefined)),
    ?assertException(error, badarg, ep_monitor_proxy:handle_call(undefined, self(), undefined)),
    ?assertException(error, badarg, ep_monitor_proxy:handle_info(undefined, undefined)).

get_last() ->
    [{doc, "Test that getting last 5 seconds yield something"}].

get_last(_Config) ->
    timer:sleep(1000),
    Last = ep_history:get_last(5),
    ?assertNotEqual([], Last).
