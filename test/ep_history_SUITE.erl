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
    get_last/0, get_last/1,
    pg_clash/0, pg_clash/1
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
    [errors, get_last, pg_clash].

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

pg_clash() ->
    [{doc, "Tests that pg does not clash if started by kernel/another app"}].

pg_clash(Config) when is_list(Config) ->
    case code:which(pg) of
        non_existing ->
            {skip, {otp_version, "pg is not supported"}};
        _ ->
            ok = application:stop(erlperf),
            {ok, Pg} = pg:start_link(),
            ok = application:start(erlperf),
            gen_server:stop(Pg)
    end.
