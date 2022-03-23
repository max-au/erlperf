%%%-------------------------------------------------------------------
%%% @author Maxim Fedorov <maximfca@gmail.com>
%%% @copyright (c) 2019 Maxim Fedorov
%%% @doc
%%%     Helpers: cluster/app sentinels.
%%% @end

-module(test_helpers).
-author("maximfca@gmail.com").

%% API
-export([
    ensure_distributed/1,
    ensure_started/2,
    ensure_stopped/1,
    maybe_undistribute/1
]).

ensure_started(App, Config) ->
    Apps = proplists:get_value(apps, Config, []),
    case lists:member(App, Apps) of
        true ->
            Config;
        false ->
            {ok, New} = application:ensure_all_started(App),
            lists:keystore(apps, 1, Config, {apps, New ++ Apps})
    end.

ensure_stopped(Config) ->
    [ok = application:stop(App) || App <- proplists:get_value(apps, Config, [])],
    proplists:delete(apps, Config).

ensure_distributed(Config) ->
    case proplists:get_value(distribution, Config) of
        undefined ->
            case erlang:is_alive() of
                false ->
                    % verify epmd running (otherwise next call fails)
                    (erl_epmd:names("localhost") =:= {error, address}) andalso
                        ([] = os:cmd("epmd -daemon")),
                    % start machine@localhost (avoiding inet:gethostname() as it fails to resolve in DNS sometimes)
                    NodeName = list_to_atom(atom_to_list(?MODULE) ++ "@localhost"),
                    {ok, Pid} = net_kernel:start([NodeName, shortnames]),
                    [{distribution, Pid} | Config];
                true ->
                    Config
            end;
        Pid when is_pid(Pid) ->
            Config
    end.

maybe_undistribute(Config) ->
    case proplists:get_value(distribution, Config) of
        undefined ->
            Config;
        Pid when is_pid(Pid) ->
            net_kernel:stop(),
            proplists:delete(distribution, Config)
    end.
