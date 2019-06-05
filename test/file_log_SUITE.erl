%%%-------------------------------------------------------------------
%%% @author Maxim Fedorov <maximfca@gmail.com>
%%% @copyright (c) 2019 Maxim Fedorov
%%% @doc
%%%     Tests file_log
%%% @end
%%% -------------------------------------------------------------------

-module(file_log_SUITE).

%% Common Test headers
-include_lib("common_test/include/ct.hrl").

%% Include stdlib header to enable ?assert() for readable output
-include_lib("stdlib/include/assert.hrl").

%% Test server callbacks
-export([
    suite/0,
    all/0,
    init_per_suite/1, end_per_suite/1,
    init_per_testcase/2, end_per_testcase/2
]).

%% Test cases
-export([
    basic/0, basic/1
]).

suite() ->
    [{timetrap, {seconds, 10}}].

init_per_suite(Config) ->
    Config.

end_per_suite(_Config) ->
    ok.

init_per_testcase(_TestCase, Config) ->
    application:load(erlperf),
    Filename = filename:join(?config(priv_dir, Config), "file_log.txt"),
    ok = application:set_env(erlperf, file_log, Filename),
    {ok, Apps} = application:ensure_all_started(erlperf),
    [{log_file, Filename}, {apps, Apps} | Config].

end_per_testcase(_TestCase, Config) ->
    [application:stop(App) || App <- ?config(apps, Config)],
    ok.

all() ->
    [basic].

basic() ->
    [{doc, "Tests file logging"}].

basic(Config) ->
    benchmark:run({timer, sleep, [1]}),
    % read the file
    Filename = ?config(log_file, Config),
    {ok, Logs} = file:read_file(Filename),
    ct:pal("~s", [Logs]),
    ?assert(byte_size(Logs) > 10).
