%%%-------------------------------------------------------------------
%%% @author dane
%%% @copyright (C) 2018, <COMPANY>
%%% @doc
%%%
%%% @end
%%% Created : 10. Dec 2018 09:19
%%%-------------------------------------------------------------------
-module(ctp_SUITE).
-author("dane").

-include_lib("common_test/include/ct.hrl").

-export([all/0, suite/0]).
-export([basic/1]).

suite() ->
    [{ct_hooks,[ts_install_cth]},
        {timetrap,{seconds,60}}].

all() ->
    [basic].

basic(Config) when is_list(Config) ->
    %
    spawn(fun () -> do_anything(1000, 1000) end),
    SampleSet = ctp:sample(all, 500, [{ctp_SUITE, '_', '_'}], spawn(fun progress_printer/0)),
    length(maps:get(undefined, SampleSet)) > 10,
    % ctp:run(all, 50),
    {ok, _} = ctp:start(),
    % start rand() module - otherwise we must handle on_load
    rand:module_info(),
    %
    ok = ctp:start_trace(#{sample => [{'_', '_', '_'}], arity => false}),
    %ok = ctp:start_trace(#{arity => true}),
    % inline 'timer:sleep()'
    do_anything(10000, 10000),
    do_other(10000, 10000),
    %
    ok = ctp:stop_trace(),
    ok = ctp:collect(#{progress => spawn(fun progress_printer/0)}),
    {ok, Grind, Trace} = ctp:format(#{format => callgrind}),
    %io:format("Trace: ~s~n", [binary:part(Grind, 1, 300)]),
    file:write_file("/tmp/callgrind.001", Grind),
    file:write_file("/tmp/data.001", term_to_binary(Trace)),
    %ctp:replay(Trace),
    %{ok, Grind, Trace} = ctp:format(#{format => none, sort => call_time}),
    %io:format("~p~n", [lists:sublist(Grind, 1, 5)]),
    %io:format("Trace: ~p~n", [Trace]),
    %file:write_file("/tmp/trace.001", io_lib:format("~p", [Trace])),
    ok = ctp:stop(),
    ok.

progress_printer() ->
    receive
        {Step, 1, _, _} ->
            io:format("~s started ", [Step]),
            progress_printer();
        {_Step, Done, Total, _} when Done rem 20 == 0->
            io:format("~b/~b ", [Done, Total]),
            progress_printer();
        {_Step, Done, Done, _} ->
            io:format(" complete.~n");
        _ ->
            progress_printer()
    end.

do_anything(0, _) -> ok;
do_anything(C, N) when C rem 1000 == 0 -> do_anything(C-1, rand:uniform(C) + N);
do_anything(C, N) -> do_anything(C-1, N).

do_other(0, _) -> ok;
do_other(C, N) when C rem 10 == 0 -> io_lib:format(".~b.", [N]);
do_other(C, N) -> do_other(C-1, N).
