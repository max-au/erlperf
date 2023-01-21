%%% @copyright (c) 2019-2023 Maxim Fedorov
%%% Smoke tests for erlperf_history.
-module(erlperf_history_SUITE).
-author("maximfca@gmail.com").

%% Common Test headers
-include_lib("stdlib/include/assert.hrl").

%% Test server callbacks
-export([suite/0, all/0]).

%% Test cases
-export([basic/1]).

suite() ->
    [{timetrap, {seconds, 10}}].

all() ->
    [basic].

%%--------------------------------------------------------------------
%% TEST CASES

basic(Config) when is_list(Config) ->
    {ok, Pg} = pg:start_link(erlperf),
    {ok, HistoryServer} = erlperf_history:start_link(1000), %% keep history for 1 second
    %% simulate a number of samples via pg
    Template = #{sched_util => 0.05},
    FutureTime = os:system_time(millisecond) + 500, %% half a second in the future, +100 ms for samples
    Nodes = [node(), 'second@anywhere'],
    Samples = [Template#{time => FutureTime + Seq * 10, node => Node} || Seq <- lists:seq(1, 10), Node <- Nodes],
    [HistoryServer ! S || S <- Samples],
    sys:get_state(HistoryServer),
    %% all of these samples must be still available
    {_Times, FullHistory} = lists:unzip(erlperf_history:get(FutureTime, FutureTime + 1000)),
    ?assertEqual(Samples, FullHistory),
    %% fire cleanup
    timer:sleep(2000),
    HistoryServer ! Template#{time => FutureTime - 1000, node => node()},
    sys:get_state(HistoryServer),
    %% ensure cleanup worked
    ?assertEqual([], erlperf_history:get(FutureTime, FutureTime + 1000)),
    %% ensure get/1,2 work
    gen:stop(HistoryServer),
    gen:stop(Pg).
