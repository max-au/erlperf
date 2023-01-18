%%% @copyright (c) 2019-2023 Maxim Fedorov
%%% @doc
%%%     Tests erlperf_file_log
%%% @end
-module(erlperf_file_log_SUITE).
-author("maximfca@gmail.com").

%% Include stdlib header to enable ?assert() for readable output
-include_lib("stdlib/include/assert.hrl").

%% Test server callbacks
-export([
    suite/0,
    all/0
]).

%% Test cases
-export([
    file_log/0, file_log/1,
    formatters/0, formatters/1
]).

suite() ->
    [{timetrap, {seconds, 10}}].

all() ->
    [formatters, file_log].

formatters() ->
    [{doc, "Basic tests for formatters like Ki (Kilo-calls) and Kb (Kilo-bytes)"}].

formatters(Config) when is_list(Config) ->
    ?assertEqual("88", erlperf_file_log:format_size(88)),
    ?assertEqual("88000", erlperf_file_log:format_number(88000)),
    ?assertEqual("881 Mb", erlperf_file_log:format_size(881 * 1024 * 1024)),
    ?assertEqual("881 Mb", erlperf_file_log:format_size(881 * 1024 * 1024)),
    ?assertEqual("123 Gb", erlperf_file_log:format_size(123 * 1024 * 1024 * 1024)),
    % rounding
    ?assertEqual("42", erlperf_file_log:format_number(42)),
    ?assertEqual("432 Ki", erlperf_file_log:format_number(431992)),
    ?assertEqual("333 Mi", erlperf_file_log:format_number(333000000)),
    ?assertEqual("999 Gi", erlperf_file_log:format_number(998500431992)).

file_log() ->
    [{doc, "Tests console and file logging sanity and equality"}].

file_log(Config) when is_list(Config) ->
    {ok, Pg} = pg:start_link(erlperf),
    {ok, Mon} = erlperf_monitor:start_link(),
    Filename = filename:join(proplists:get_value(priv_dir, Config), "file_log_manual.txt"),
    ok = ct:capture_start(),
    {ok, FileLog} = erlperf_file_log:start_link(Filename),
    {ok, ConsoleLog} = erlperf_file_log:start_link(erlang:group_leader()),
    erlperf:run(timer, sleep, [1]),
    ok = ct:capture_stop(),
    [gen:stop(Srv) || Srv <- [ConsoleLog, FileLog, Mon, Pg]],
    ConsoleLines = ct:capture_get(),
    Console = list_to_binary(lists:concat(ConsoleLines)),
    {ok, Logs} = file:read_file(Filename),
    ?assertEqual(Logs, Console),
    ?assert(length(ConsoleLines) > 3, {"at least header and 3 samples are expected to be printed", ConsoleLines}),
    %% header must contain the job
    [Hdr, S1, S2, S3 | _] = [string:trim(lists:last(string:lexemes(Line, " "))) || Line <- ConsoleLines],
    ?assert(is_pid(list_to_pid(Hdr))),
    Samples = [list_to_integer(S) || S <- [S1, S2, S3]],
    [?assert(Sample > 10 andalso Sample < 1000) || Sample <- Samples].
