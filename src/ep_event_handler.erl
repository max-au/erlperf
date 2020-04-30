%%%-------------------------------------------------------------------
%%% @author Maxim Fedorov <maximfca@gmail.com>
%%% @copyright (C) 2019, Maxim Fedorov
%%% @doc
%%%   Generic event handler, converting gen_event
%%%     callbacks into messages. Allows collecting
%%%     events from remote nodes.
%%% @end
-module(ep_event_handler).
-author("maximfca@gmail.com").

-behavior(gen_event).

-export([
    subscribe/1,
    subscribe/2,
    unsubscribe/1,
    unsubscribe/2
]).

%% gen_event callbacks
-export([
    init/1,
    handle_call/2,
    handle_event/2
]).

-spec subscribe(gen_event:emgr_ref()) -> term().
subscribe(GenEvent) ->
    gen_event:add_handler(GenEvent, ?MODULE, self()).

-spec subscribe(gen_event:emgr_ref(), term()) -> term().
subscribe(GenEvent, Tag) ->
    gen_event:add_handler(GenEvent, ?MODULE, {self(), Tag}).

-spec unsubscribe(gen_event:emgr_ref()) -> term().
unsubscribe(GenEvent) ->
    gen_event:delete_handler(GenEvent, ?MODULE, self()).

-spec unsubscribe(gen_event:emgr_ref(), term()) -> term().
unsubscribe(GenEvent, Tag) ->
    gen_event:delete_handler(GenEvent, ?MODULE, {self(), Tag}).

-type state() :: pid() | atom() | {pid() | atom(), term()}.

%% gen_event init
-spec init(state()) -> {ok, state()}.
init(Self) ->
    {ok, Self}.

-spec handle_call({pid(), reference()}, state()) -> no_return().
handle_call(_From, _State) ->
    error(badarg).

%% gen_event
-spec handle_event(term(), state()) -> no_return().
handle_event(Event, Proc) when is_pid(Proc) ->
    Proc ! Event,
    {ok, Proc};
handle_event(Event, {Proc, Tag} = Tagged) ->
    Proc ! {Tag, Event},
    {ok, Tagged}.
