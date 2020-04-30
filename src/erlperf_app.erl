%%%-------------------------------------------------------------------
%%% @author Maxim Fedorov <maximfca@gmail.com>
%%% @copyright (C) 2019, Maxim Fedorov
%%%     Benchmarking application
%%% @end
%%%-------------------------------------------------------------------

-module(erlperf_app).

-behaviour(application).

-export([start/2, stop/1]).

-spec start(application:start_type(), term()) -> {ok, pid()}.
start(_StartType, _StartArgs) ->
    erlperf_sup:start_link().

-spec stop(term()) -> ok.
stop(_State) ->
    ok.

