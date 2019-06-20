%%%-------------------------------------------------------------------
%%% @author Maxim Fedorov <maximfca@gmail.com>
%%% @copyright (C) 2019, Maxim Fedorov
%%% @doc
%%%   Writes monitoring events to file.
%%% @end
-module(ep_file_log).
-author("maximfca@gmail.com").

-behaviour(gen_server).

%% API
-export([
    start/1,
    stop/1,
    start_link/1
]).

%% gen_server callbacks
-export([
    init/1,
    handle_call/3,
    handle_cast/2,
    handle_info/2,
    terminate/2
]).

-include("monitor.hrl").

%%--------------------------------------------------------------------
%% @doc
%% Starts the server
-spec(start_link(Filename :: string() | file:io_device()) ->
    {ok, Pid :: pid()} | ignore | {error, Reason :: term()}).
start_link(Filename) ->
    gen_server:start_link(?MODULE, [Filename], []).

%%--------------------------------------------------------------------
%% @doc
%% Starts the server with a different name and/or file.
%% Server is started outside of supervision tree.
-spec start(Target :: file:filename() | file:io_device()) -> {ok, Pid :: pid()} | {error, Reason :: term()}.
start(Filename) ->
    supervisor:start_child(ep_file_log_sup, [Filename]).

%%--------------------------------------------------------------------
%% @doc
%% Stops the server, if started stand-alone. If it was started as a part
%%  of supervision tree, server will restart.
-spec stop(pid()) -> ok.
stop(Pid) ->
    supervisor:terminate_child(ep_file_log_sup, Pid).

%%%===================================================================
%%% gen_server callbacks

%% Repeat header every 30 lines (by default)
-define(LOG_REPEAT_HEADER, 30).

%% System monitor state
-record(state, {
    % file logger counter
    log_counter = ?LOG_REPEAT_HEADER :: non_neg_integer(),
    % when to print the header once again
    log_limit = ?LOG_REPEAT_HEADER :: pos_integer(),
    % file descriptor
    log_file :: file:io_device(),
    % current format line
    format :: string(),
    % saved list of job IDs executed previously
    jobs = [] :: [integer()]
}).

%% gen_server init
init([Target]) ->
    % subscribe to monitor events
    erlang:process_flag(trap_exit, true),
    ep_event_handler:subscribe(?SYSTEM_EVENT),
    case is_list(Target) of
        true ->
            {ok, LogFile} = file:open(Target, [raw, append]),
            {ok, #state{log_file = LogFile}};
        false ->
            {ok, #state{log_file = Target}}
    end.

handle_call(_Request, _From, _State) ->
    error(badarg).

handle_cast(_Request, _State) ->
    error(badarg).

handle_info(#monitor_sample{jobs = Jobs} = Sample, #state{log_file = File} = State) ->
    {JobIds, Ts} = lists:unzip(Jobs),
    State1 = maybe_write_header(JobIds, State),
    % actual line
    TimeFormat = calendar:system_time_to_rfc3339(Sample#monitor_sample.time div 1000),
    Formatted = iolist_to_binary(io_lib:format(State1#state.format, [
        TimeFormat,
        Sample#monitor_sample.sched_util,
        Sample#monitor_sample.dcpu,
        Sample#monitor_sample.dio,
        Sample#monitor_sample.processes,
        Sample#monitor_sample.ports,
        Sample#monitor_sample.ets,
        erlperf:format_size(Sample#monitor_sample.memory_total),
        erlperf:format_size(Sample#monitor_sample.memory_processes),
        erlperf:format_size(Sample#monitor_sample.memory_binary),
        erlperf:format_size(Sample#monitor_sample.memory_ets)
    ] ++ [erlperf:format_number(T) || T <- Ts])),
    ok = file:write(File, Formatted),
    {noreply, State1};

handle_info(_Info, _State) ->
    error(badarg).

terminate(_Reason, _State) ->
    ep_event_handler:unsubscribe(?SYSTEM_EVENT).

%%%===================================================================
%%% Internal functions

maybe_write_header(Jobs, #state{log_counter = LC, log_limit = LL, jobs = Prev} = State) when LC >= LL; Jobs =/= Prev ->
    write_header(State#state{jobs = Jobs});
maybe_write_header(_, State) ->
    State#state{log_counter = State#state.log_counter + 1}.

write_header(#state{log_file = File, jobs = Jobs} = State) ->
    JobCount = length(Jobs),
    Format = "~s ~6.2f ~6.2f ~6.2f ~8b ~8b ~7b ~9s ~9s ~9s ~9s" ++
        lists:flatten(lists:duplicate(JobCount, "~11s")) ++ "~n",
    JobIds = list_to_binary(lists:flatten([io_lib:format("  ~6p", [J]) || J <- Jobs])),
    Header =  <<"\nYYYY-MM-DDTHH:MM:SS-oo:oo  Sched   DCPU    DIO    Procs    Ports     ETS Mem Total  Mem Proc   Mem Bin   Mem ETS", JobIds/binary, "\n">>,
    ok = file:write(File, Header),
    State#state{format = Format, log_counter = 0}.
