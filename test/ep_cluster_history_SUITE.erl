%%%-------------------------------------------------------------------
%%% @author Maxim Fedorov <maximfca@gmail.com>
%%% @copyright (c) 2019 Maxim Fedorov
%%% @doc
%%%     Tests cluster monitor
%%% @end

-module(ep_cluster_history_SUITE).
-author("maximfca@gmail.com").

%% Common Test headers

-include_lib("stdlib/include/assert.hrl").

-include_lib("erlperf/include/monitor.hrl").

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
    monitor_cluster/0, monitor_cluster/1
]).

-export([
    handle_update/2
]).

suite() ->
    [{timetrap, {seconds, 10}}].

init_per_suite(Config) ->
    % for this one, need distributed node + full app running
    test_helpers:ensure_started(erlperf, test_helpers:ensure_distributed(Config)).

end_per_suite(Config) ->
    test_helpers:maybe_undistribute(test_helpers:ensure_stopped(Config)).

init_per_testcase(_TestCase, Config) ->
    Config.

end_per_testcase(_TestCase, _Config) ->
    ok.

all() ->
    [errors, monitor_cluster].

%%--------------------------------------------------------------------
%% TEST CASES

errors() ->
    [{doc, "Test that we do not handle unknown stuff"}].

errors(_Config) ->
    ?assertException(error, badarg, ep_cluster_history:handle_cast(undefined, undefined)),
    ?assertException(error, badarg, ep_cluster_history:handle_call(undefined, self(), undefined)),
    ?assertException(error, badarg, ep_cluster_history:handle_info(undefined, undefined)),
    %
    ?assertException(error, badarg, ep_cluster_monitor:handle_cast(undefined, undefined)),
    ?assertException(error, badarg, ep_cluster_monitor:handle_call(undefined, self(), undefined)),
    ?assertException(error, badarg, ep_cluster_monitor:handle_info(undefined, undefined)),
    %
    ?assertException(error, badarg, ep_job:handle_cast(undefined, undefined)),
    ?assertException(error, badarg, ep_job:handle_call(undefined, self(), undefined)),
    ?assertException(error, badarg, ep_job:handle_info(undefined, undefined)).


monitor_cluster() ->
    [{doc, "Tests cluster-wide history, also piggy-back for cluster_monitor here"}].

%% TODO: remove piggy-backing

monitor_cluster(Config) ->
    Started = erlang:system_time(millisecond),
    Control = self(),
    % start cluster monitor for [time, sched_util, jobs] only
    {ok, Pid} = ep_cluster_monitor:start({?MODULE, handle_update, [Control]}, [time, sched_util, jobs]),
    %
    {IoProc, GL} = test_helpers:redirect_io(),
    {ok, ClusterMonPid} = ep_cluster_monitor:start(),
    LogFile = filename:join(proplists:get_value(priv_dir, Config), "cluster_log.txt"),
    {ok, ClusterFilePid} = ep_cluster_monitor:start(LogFile, [time, jobs]),
    % start a benchmark on the different node, and monitor progress
    % link the process to kill it if timetrap fires
    Remote = spawn_link(
        fun () ->
            erlperf:run({timer, sleep, [10]}, #{concurrency => 2, isolation => #{}}),
            unlink(Control)
        end),
    % start a job locally
    {ok, Job} = ep_job:start({timer, sleep, [1]}),
    % get cluster history samples for 2 nodes
    {Total, Samples} = poll_history([], erlang:system_time(millisecond), 3),
    ok = ep_job:stop(Job),
    unlink(Remote),
    exit(Remote, kill),
    % some history must be there as well
    History = ep_cluster_history:get(Started),
    %
    ?assertNotEqual([], History),
    %
    Console = test_helpers:collect_io({IoProc, GL}),
    %
    ok = ep_cluster_monitor:stop(ClusterFilePid),
    ok = ep_cluster_monitor:stop(ClusterMonPid),
    ok = ep_cluster_monitor:stop(Pid),
    %
    ?assertNotEqual([], Console),
    %
    ?assertNotEqual([], Total),
    ?assertNotEqual([], Samples).

handle_update(Sample, [Control]) ->
    Control ! {monitor, Sample},
    [Control].

-define(INTERVAL, 1000).

poll_history(Events, From, 0) when is_integer(From) ->
    poll_history(Events, [], 0);
poll_history(Events, Samples, 0) ->
    % collect cluster_monitor events too
    receive
        {monitor, Sample}  ->
            poll_history(Events, [Sample | Samples], 0)
    after
        1 ->
            {Events, Samples}
    end;
poll_history(Events, From, Count) ->
    timer:sleep(?INTERVAL),
    History = ep_cluster_history:get(From, From + ?INTERVAL),
    poll_history([History | Events], From + ?INTERVAL, Count - 1).
