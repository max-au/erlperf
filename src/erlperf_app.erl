%%% @copyright (C) 2019-2022, Maxim Fedorov
%%% @doc
%%% Continuous benchmarking application behaviour.
%%% @end
-module(erlperf_app).
-author("maximfca@gmail.com").

-behaviour(application).

-export([start/2, stop/1]).

-spec start(application:start_type(), term()) -> {ok, pid()}.
start(_StartType, _StartArgs) ->
    {ok, Sup} = erlperf_sup:start_link(),
    {ok, Sup}.

-spec stop(term()) -> ok.
stop(_State) ->
    ok.

