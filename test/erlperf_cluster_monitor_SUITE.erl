%%% @copyright (c) 2019-2023 Maxim Fedorov
%%% @doc
%%% Tests combination of erlperf_monitor, erlperf_cluster_monitor,
%%%  erlperf_history and erlperf_job. This is an integration test
%%%  for the entire cluster monitoring subsystem.
%%% @end
-module(erlperf_cluster_monitor_SUITE).
-author("maximfca@gmail.com").

%% Common Test headers
-include_lib("stdlib/include/assert.hrl").

%% Test server callbacks
-export([suite/0, all/0]).

%% Test cases
-export([monitor_cluster/0, monitor_cluster/1]).

-export([handle_update/2]).

suite() ->
    [{timetrap, {seconds, 20}}].

all() ->
    [monitor_cluster].

%%--------------------------------------------------------------------
%% TEST CASES

monitor_cluster() ->
    [{doc, "Tests 3 separate cluster monitors watching the same data"}].

monitor_cluster(Config) ->
    {ok, Pg} = pg:start_link(erlperf),
    {ok, HistPid} = erlperf_history:start_link(),

    Control = self(),
    LogFile = filename:join(proplists:get_value(priv_dir, Config), "cluster_log.txt"),
    ok = ct:capture_start(),

    %% TODO deliberately omit memory fields?
    AllFields = [time, node, sched_util, dcpu, dio, processes, ports, ets,
        memory_total, memory_processes, memory_binary, memory_ets, jobs],

    %% start cluster monitor
    {ok, ClusterHandlePid} = erlperf_cluster_monitor:start_link({?MODULE, handle_update, [Control]}, 1000, AllFields),
    %% start another cluster monitor (now printing to console)
    {ok, ClusterMonPid} = erlperf_cluster_monitor:start_link(),
    %% start 3rd cluster monitor printing to a file
    {ok, ClusterFilePid} = erlperf_cluster_monitor:start_link(LogFile, 1000, AllFields),

    Started = os:system_time(millisecond),
    %% simulate 3 jobs from 3 nodes sending cluster 3 data samples (monitor is expected to eventually catch those)
    LocalJobs = [{self(), 100}, {Pg, 200}],
    Node2Jobs = [{HistPid, 500}],
    Nodes = [{node(), LocalJobs}, {'node2@localhost', Node2Jobs}, {'node3@localhost', []}],
    Times = [Started + Seq * 1000 || Seq <- lists:seq(1, 3)],
    %% common message template
    Template = #{sched_util => 0.1, dcpu => 0.1, dio => 0.1, processes => 10, ports => 20, ets => 30,
        memory_total => 100, memory_processes => 10, memory_binary => 20, memory_ets => 30},
    Samples = [HistPid ! Template#{node => Node, jobs => Jobs, time => Time} || {Node, Jobs} <- Nodes, Time <- Times],

    %% wait for 3 monitoring handler calls from the cluster monitor (3 seconds)
    RawHandlerHistory = poll_history([], 3),
    ClusterHandlerHistory = [S || {_T, S} <- RawHandlerHistory],
    RawHistory = erlperf_history:get(Started),
    History = [S || {_T, S} <- RawHistory],

    %% capture text output
    ct:capture_stop(),
    Console = ct:capture_get(),

    {ok, FileBin} = file:read_file(LogFile),
    [ok = gen:stop(Pid) || Pid <- [ClusterFilePid, ClusterMonPid, ClusterHandlePid, HistPid, Pg]],

    %% all 5 sources should be identical: cluster history, raw history, sent samples
    %% and parsed files

    ct:pal("File:~n~s", [FileBin]),

    %% compare Samples to ClusterHandleHistory
    ?assertEqual([], ClusterHandlerHistory -- Samples, {extra_events, ClusterHandlerHistory, expected, Samples}),
    ?assertEqual([], Samples -- ClusterHandlerHistory, {missing_events, Samples, expected, ClusterHandlerHistory}),

    %% Samples to History
    ?assertEqual([], History -- Samples, {extra_events, History, expected, Samples}),
    ?assertEqual([], Samples -- History, {missing_events, Samples, expected, History}),

    %% flatten + split lines of console output
    NewLine = io_lib:nl(),
    [ConsoleHdr | ConsoleData] = string:split(lists:flatten(Console), NewLine, all),
    [FileHdr | FileData] = string:split(binary_to_list(FileBin), NewLine, all),

    %% compare headers and first 3 lines of data
    ?assertEqual(ConsoleHdr, FileHdr),
    ?assertEqual(lists:sublist(ConsoleData, 1, 3), lists:sublist(FileData, 1, 3)),

    %% TODO: parse first 3 lines of file/console output and find those samples
    %?assertEqual([ExpectedHeader | ExpectedData], lists:sublist(FileLines, 1, 4)),
    %?assertEqual([ExpectedHeader | ExpectedData], lists:sublist(ConsoleLines, 1, 4)),
    ok.

handle_update(Sample, [Control]) ->
    Control ! {monitor, Sample},
    [Control].

-define(INTERVAL, 1000).

poll_history(Events, 0) ->
    lists:reverse(Events);
poll_history(Events, Count) ->
    % collect cluster_monitor events too
    receive
        {monitor, Sample}  ->
            poll_history(Sample ++ Events, Count - 1)
    after 5000 ->
        erlang:error(timeout)
    end.
