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
    basic/0, basic/1,
    console/0, console/1,
    errors/1,
    manual_start/0, manual_start/1
]).

suite() ->
    [{timetrap, {seconds, 10}}].

init_per_suite(Config) ->
    Filename = filename:join(?config(priv_dir, Config), "file_log.txt"),
    ok = application:set_env(erlperf, ep_file_log, Filename),
    ok = application:start(erlperf),
    application:unset_env(erlperf, ep_file_log),
    test_helpers:ensure_started(erlperf, [{log_file, Filename} | Config]).

end_per_suite(Config) ->
    test_helpers:ensure_stopped(Config).

init_per_testcase(basic, Config) ->
    Config;
init_per_testcase(_TestCase, Config) ->
    Config.

end_per_testcase(_TestCase, Config) ->
    Config.

groups() ->
    [{all, [parallel], [basic, console, errors, manual_start]}].

%% cannot run basic & manual_start in parallel, due to specific "init" for basic.
all() ->
    [{group, all}].

basic() ->
    [{doc, "Tests file logging"}].

basic(Config) ->
    erlperf:run({timer, sleep, [1]}),
    % read the file
    Filename = ?config(log_file, Config),
    {ok, Logs} = file:read_file(Filename),
    ?assert(byte_size(Logs) > 10).

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