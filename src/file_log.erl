%%%-------------------------------------------------------------------
%%% @author Maxim Fedorov <maximfca@gmail.com>
%%% @copyright (C) 2019, Maxim Fedorov
%%% @doc
%%%   Writes monitoring events to file.
%%% @end
-module(file_log).
-author("maximfca@gmail.com").

-behaviour(gen_server).

%% API
-export([
    start_link/1
]).

%% gen_server callbacks
-export([
    init/1,
    handle_call/3,
    handle_cast/2,
    handle_info/2
]).

-include("monitor.hrl").

%%--------------------------------------------------------------------
%% @doc
%% Starts the server
-spec(start_link(Filename :: file:filename()) ->
    {ok, Pid :: pid()} | ignore | {error, Reason :: term()}).
start_link(Filename) ->
    gen_server:start_link({local, ?MODULE}, ?MODULE, [Filename], []).


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
    log_file :: file:io_device() | undefined,
    % current format line
    format :: string(),
    % saved list of job IDs executed previously
    jobs = [] :: [integer()]
}).

%% gen_server init
init([Filename]) ->
    % subscribe to monitor events
    event_handler:subscribe(system_event),
    {ok, LogFile} = file:open(Filename, [raw, append]),
    {ok, #state{log_file = LogFile}}.

handle_call(_Request, _From, _State) ->
    error(badarg).

handle_cast(_Request, _State) ->
    error(badarg).

handle_info(#monitor_sample{jobs = Jobs} = Sample, #state{log_file = File} = State) ->
    {JobIds, Ts} = lists:unzip(Jobs),
    State1 = maybe_write_header(JobIds, State),
    % actual line
    {{Y, M, D}, {H, Min, Sec}} = calendar:gregorian_seconds_to_datetime(Sample#monitor_sample.time div 1000),
    Formatted = iolist_to_binary(io_lib:format(State1#state.format, [
        Y, M, D, H, Min, Sec,
        Sample#monitor_sample.sched_util,
        Sample#monitor_sample.dcpu,
        Sample#monitor_sample.dio,
        Sample#monitor_sample.processes,
        Sample#monitor_sample.ports,
        Sample#monitor_sample.ets,
        format_size(Sample#monitor_sample.memory_total),
        format_size(Sample#monitor_sample.memory_processes),
        format_size(Sample#monitor_sample.memory_binary),
        format_size(Sample#monitor_sample.memory_ets)
    ] ++ [format_number(T) || T <- Ts])),
    ok = file:write(File, Formatted),
    {noreply, State1};

handle_info(_Info, _State) ->
    error(badarg).

%%%===================================================================
%%% Internal functions

maybe_write_header(Jobs, #state{log_counter = LC, log_limit = LL, jobs = Prev} = State) when LC >= LL; Jobs =/= Prev ->
    write_header(State#state{jobs = Jobs});
maybe_write_header(_, State) ->
    State#state{log_counter = State#state.log_counter + 1}.

write_header(#state{log_file = File, jobs = Jobs} = State) ->
    JobCount = length(Jobs),
    Format = "~4.4.0w-~2.2.0w-~2.2.0wT~2.2.0w:~2.2.0w:~2.2.0w ~6.2f ~6.2f ~6.2f ~8b ~8b ~7b ~9s ~9s ~9s ~9s" ++
        lists:flatten(lists:duplicate(JobCount, "~8s")) ++ "~n",
    JobIds = list_to_binary(lists:flatten([io_lib:format("  ~6b", [J]) || J <- Jobs])),
    Header =  <<"\nYYYY-MM-DDTHH:MM:SS  Sched   DCPU    DIO    Procs    Ports     ETS Mem Total  Mem Proc   Mem Bin   Mem ETS", JobIds/binary, "\n">>,
    ok = file:write(File, Header),
    State#state{format = Format, log_counter = 0}.

format_number(Num) when Num > 100000000000 ->
    integer_to_list(Num div 1000000000) ++ " Gi";
format_number(Num) when Num > 100000000 ->
    integer_to_list(Num div 1000000) ++ " Mi";
format_number(Num) when Num > 100000 ->
    integer_to_list(Num div 1000) ++ " Ki";
format_number(Num) ->
    integer_to_list(Num).

format_size(Num) when Num > 1024*1024*1024 * 100 ->
    integer_to_list(Num div 1024*1024*1024) ++ " Gb";
format_size(Num) when Num > 1024*1024*100 ->
    integer_to_list(Num div 1024 * 1024) ++ " Mi";
format_size(Num) when Num > 1024 * 100 ->
    integer_to_list(Num div 1024) ++ " Ki";
format_size(Num) ->
    integer_to_list(Num).
