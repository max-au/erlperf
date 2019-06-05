%%%-------------------------------------------------------------------
%%% @author Maxim Fedorov <maximfca@gmail.com>
%%% @copyright (C) 2019, Maxim Fedorov
%%% @doc
%%%   Generic event handler, converting gen_event
%%%     callbacks into messages.
%%% @end
-module(event_handler).
-author("maximfca@gmail.com").

-behavior(gen_event).

-export([subscribe/1, unsubscribe/1]).

%% gen_event callbacks
-export([
    init/1,
    handle_call/2,
    handle_event/2
]).

subscribe(GenEvent) ->
    gen_event:add_handler(GenEvent, ?MODULE, self()).

unsubscribe(GenEvent) ->
    gen_event:add_handler(GenEvent, ?MODULE, self()).

%% gen_event init
init(Self) when is_pid(Self) ->
    {ok, Self}.

handle_call(_From, _State) ->
    error(badarg).

%% gen_event
handle_event(Event, Proc) ->
    Proc ! Event,
    {ok, Proc}.
