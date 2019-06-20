%%%-------------------------------------------------------------------
%%% @author Maxim Fedorov <maximfca@gmail.com>
%%% @copyright (c) 2019 Maxim Fedorov
%%% @doc
%%%     Tests file_log
%%% @end
%%% -------------------------------------------------------------------

-module(ep_file_log_SUITE).

%% Common Test headers
-include_lib("common_test/include/ct.hrl").

%% Include stdlib header to enable ?assert() for readable output
-include_lib("stdlib/include/assert.hrl").

%% Test server callbacks
-export([
    suite/0,
    all/0,
    groups/0,
    init_per_suite/1, end_per_suite/1,
    init_per_testcase/2, end_per_testcase/2
]).

%% Test cases
-export([
    console/0, console/1,
    errors/1,
    manual_start/0, manual_start/1
]).

suite() ->
    [{timetrap, {seconds, 10}}].

init_per_suite(Config) ->
    test_helpers:ensure_started(erlperf, Config).

end_per_suite(Config) ->
    test_helpers:ensure_stopped(Config).

init_per_testcase(basic, Config) ->
    Config;
init_per_testcase(_TestCase, Config) ->
    Config.

end_per_testcase(_TestCase, Config) ->
    Config.

groups() ->
    [{all, [parallel], [console, errors, manual_start]}].

%% cannot run basic & manual_start in parallel, due to specific "init" for basic.
all() ->
    [{group, all}].

console() ->
    [{doc, "Tests console logging"}].

console(_Config) ->
    {IoProc, GL} = test_helpers:redirect_io(),
    {ok, Pid} = ep_file_log:start(IoProc),
    erlperf:run({timer, sleep, [1]}),
    ep_file_log:stop(Pid),
    Console = test_helpers:collect_io({IoProc, GL}),
    ?assertNotEqual([], Console).

% test that we do *not* handle unknown stuff
errors(_Config) ->
    ?assertException(error, badarg, ep_file_log:handle_cast(undefined, undefined)),
    ?assertException(error, badarg, ep_file_log:handle_call(undefined, self(), undefined)),
    ?assertException(error, badarg, ep_file_log:handle_info(undefined, undefined)),
    %% piggy-backing...
    ?assertException(error, badarg, ep_event_handler:handle_call(undefined, undefined)).

manual_start() ->
    [{doc, "Tests manual startup of file log"}].

manual_start(Config) ->
    Filename = filename:join(?config(priv_dir, Config), "file_log_manual.txt"),
    {ok, Pid} = ep_file_log:start(Filename),
    erlperf:run({timer, sleep, [1]}),
    ep_file_log:stop(Pid),
    {ok, Logs} = file:read_file(Filename),
    ?assert(byte_size(Logs) > 10).