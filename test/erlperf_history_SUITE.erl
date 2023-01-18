%%% @copyright (c) 2019-2023 Maxim Fedorov
%%% @doc
%%% Tests combination of erlperf_monitor, erlperf_cluster_monitor,
%%%  erlperf_history and erlperf_job. This is an integration test
%%%  for the entire cluster monitoring subsystem.
%%% @end
-module(erlperf_history_SUITE).
-author("maximfca@gmail.com").

%% Common Test headers

-include_lib("stdlib/include/assert.hrl").

%% Test server callbacks
-export([suite/0, all/0]).

%% Test cases
-export([
    monitor_cluster/0, monitor_cluster/1
]).

-export([
    handle_update/2
]).

suite() ->
    [{timetrap, {seconds, 10}}].

all() ->
    [monitor_cluster].

%%--------------------------------------------------------------------
%% TEST CASES

monitor_cluster() ->
    [{doc, "Tests cluster-wide history, also piggy-back for cluster_monitor here"}].

%% TODO: remove piggy-backing

monitor_cluster(Config) ->
    Started = erlang:system_time(millisecond),

    {ok, AppSup} = erlperf_sup:start_link(),
    ?assertNotEqual(undefined, whereis(erlperf_monitor)),
    {ok, HistPid} = erlperf_history:start_link(),

    Control = self(),
    LogFile = filename:join(proplists:get_value(priv_dir, Config), "cluster_log.txt"),
    ok = ct:capture_start(),

    AllFields = [time, sched_util, dcpu, dio, processes, ports, ets, memory_total, memory_processes, memory_ets, jobs],

    %% start cluster monitor
    {ok, ClusterHandlePid} = erlperf_cluster_monitor:start_link({?MODULE, handle_update, [Control]}, AllFields),
    %% start another cluster monitor (now printing to console)
    {ok, ClusterMonPid} = erlperf_cluster_monitor:start_link(erlang:group_leader(), AllFields),
    %% start 3rd cluster monitor printing to a file
    {ok, ClusterFilePid} = erlperf_cluster_monitor:start_link(LogFile, AllFields),

    %% start a benchmark on the different node, and monitor progress
    %% link the process to kill it if timetrap fires
    Remote = spawn_link(
        fun () ->
            try
                erlperf:run({timer, sleep, [10]}, #{concurrency => 2, isolation => #{}}),
                Control ! {done, self()}
            catch Class:Reason:Stack ->
                Control ! {error, self(), Class, Reason, Stack}
            end
        end),

    %% start a job locally
    {ok, Job} = erlperf_job:start(#{runner => {timer, sleep, [2]}}),
    {ok, Job2} = erlperf_job:start(#{runner => {timer, sleep, [10]}}),
    %% set concurrency
    erlperf_job:set_concurrency(Job, 1),
    erlperf_job:set_concurrency(Job2, 1),

    %% get cluster history samples for 2 nodes
    Samples = poll_history([], 3),
    History = erlperf_history:get(Started),

    %% capture text output
    ct:capture_stop(),
    Console = ct:capture_get(),

    %% stop local jobs
    ok = gen:stop(Job2),
    ok = gen:stop(Job),

    %% wait for remote job to stop
    receive
        {done, Remote} ->
            ok;
        {error, Remote, C, R, S} ->
            erlang:error({remote, C, R, S})
    after 5000 ->
        erlang:error({timeout, stopping, Remote})
    end,

    {ok, FileBin} = file:read_file(LogFile),
    [ok = gen:stop(Pid) || Pid <- [ClusterFilePid, ClusterMonPid, ClusterHandlePid, HistPid, AppSup]],
    %% verify historical samples are present in the history server
    ?assertNotEqual([], History),
    SmallHistory = [{N, maps:with(AllFields, Evt)} || {N, Evt} <- History],
    ?assertEqual([], Samples -- SmallHistory, {missing_events, Samples, SmallHistory}),
    %% next line is commented out: the "small" history is actually the full history that
    %%  may contain more events
    %% ?assertEqual([], SmallHistory -- Samples, {extra_events, SmallHistory, Samples}),

    %% Samples from the local node must contain 2 jobs with non-zero count
    %% Remote samples have 1 job
    [begin
         Node =:= node() andalso ?assertEqual(2, length(Jobs), {jobs, Node, Jobs}),
         [?assert(Count > 0, {count, Node, Jobs}) || {_Job, Count} <- Jobs]
     end || {Node, #{jobs := Jobs}} <- Samples],

    %% verify console output vs. file output
    ?assertNotEqual([], Console),
    ConsoleBin = list_to_binary(lists:flatten(Console)),

    %% parse file and compare with Samples
    FileSamples = binary_to_samples(FileBin),
    ConsoleSamples = binary_to_samples(ConsoleBin),
    ?assertEqual([], FileSamples -- Samples, {missing_events, FileSamples -- Samples}),
    ?assertEqual([], ConsoleSamples -- Samples, {missing_events, ConsoleSamples -- Samples}).

binary_to_samples(Bin) ->
    Split = binary:split(Bin, <<"\n">>, [global]),
    Parsed = [[Col || Col <- binary:split(Line, <<" ">>, [global]), Col =/= <<>>] || Line <- Split, Line =/= <<>>],
    [{binary_to_atom(Node), #{time => calendar:rfc3339_to_system_time(binary_to_list(DateTime)),
        sched_util => binary_to_float(Sched), jobs => Jobs}}
        || [Node, DateTime, Sched, Jobs] <- Parsed].

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
