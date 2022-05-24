%%% @copyright (C) 2019-2022, Maxim Fedorov
%%% @doc
%%% Command line interface adapter.
%%% @end
-module(erlperf_cli).
-author("maximfca@gmail.com").

%% Public API: escript
-export([
    main/1
]).

%% @doc Simple command-line benchmarking interface.
%% Example: erlperf 'rand:uniform().'
-spec main([string()]) -> no_return().
main(Args) ->
    Prog = #{progname => "erlperf"},
    try
        RunOpts0 = argparse:parse(Args, arguments(), Prog),

        %% turn off logger unless verbose output is requested
        maps:get(verbose, RunOpts0, false) =:= false andalso
            begin
                logger:add_primary_filter(suppress_sasl, {
                    fun(#{meta := #{error_logger := #{tag := Tag}}}, _) when Tag =:= error; Tag =:= error_report ->
                            stop;
                        (_, _) ->
                            ignore
                    end, ok})
            end,

        %% timed benchmarking is not compatible with many options, and may have "loop" written as 100M, 100K
        %% TODO: implement mutually exclusive groups in argparse
        RunOpts =
            case maps:find(loop, RunOpts0) of
                error ->
                    RunOpts0;
                {ok, Str} ->
                    [erlang:error({loop, Option}) || Option <-
                        [concurrency, sample_duration, samples, waarmup, cv], is_map_key(Option, RunOpts0)],
                    RunOpts0#{loop => parse_loop(Str)}
                end,

        %% add code paths
        [case code:add_path(P) of true -> ok; {error, Error} -> erlang:error({add_path, {P,Error}}) end
            || P <- maps:get(code_path, RunOpts, [])],
        %% find all runners
        Code0 = [parse_code(C) || C <- maps:get(code, RunOpts)],
        %% find associated init, init_runner, done
        {_, Code} = lists:foldl(fun callable/2, {RunOpts, Code0},
            [{init, init_all}, {init_runner, init_runner_all}, {done, done_all}]),
        %% figure out whether concurrency run is requested
        COpts = case maps:find(squeeze, RunOpts) of
                    {ok, true} ->
                        maps:with([min, max, threshold], RunOpts);
                    error ->
                        #{}
                end,
        ROpts = maps:with([loop, concurrency, samples, sample_duration, cv, isolation, warmup, verbose],
            RunOpts),
        %% when isolation is requested, the node must be distributed
        is_map_key(isolation, RunOpts) andalso (not erlang:is_alive())
            andalso net_kernel:start([list_to_atom(lists:concat(
            ["erlperf-", erlang:unique_integer([positive]), "-", os:getpid()])), shortnames]),
        %% do the actual run
        main_impl(ROpts, COpts, Code)
    catch
        error:{argparse, Reason} ->
            Fmt = argparse:format_error(Reason, arguments(), Prog),
            format(info, "Error: ~s", [Fmt]);
        throw:{parse, FunName, Other} ->
            format(error, "Unable to read file named '~s' (expected to contain call chain recording)~nReason: ~p\n"
                "Did you forget to end your function with period? (dot)~n", [FunName, Other]);
        error:{add_path, {Path, Error}} ->
            format(error, "Error adding code path ~s: ~p~n", [Path, Error]);
        error:{generic, Error} ->
            format(error, "Error: ~s~n", [Error]);
        error:{loop, Option} ->
            format(error, "Timed benchmarking is not compatible with ~s~n", [Option]);
        error:{generate, {parse, FunName, Error}} ->
            format(error, "Parse error for ~s: ~s~n", [FunName, lists:flatten(Error)]);
        error:{generate, {What, WhatArity, requires, Dep}} ->
            format(error, "~s/~b requires ~s function defined~n", [What, WhatArity, Dep]);
        error:{compile, Errors, Warnings} ->
            Errors =/= [] andalso format(error, "Compile error: ~s~n", [compile_errors(Errors)]),
            Warnings =/= [] andalso format(warning, "Warning: ~s~n", [compile_errors(Warnings)]);
        error:{benchmark, {'EXIT', Job, Error}} ->
            node(Job) =/= node() andalso format(error, "~s reported an error:~n", [node(Job)]),
            format(error, "~p~n", [Error]);
        Cls:Rsn:Stack ->
            format(error, "Unhandled exception: ~ts:~p~n~p~n", [Cls, Rsn, Stack])
    after
        logger:remove_primary_filter(suppress_sasl)
    end.

%% formats compiler errors/warnings
compile_errors([]) -> "";
compile_errors([{_, []} | Tail]) ->
    compile_errors(Tail);
compile_errors([{L, [{_Anno, Mod, Err} | T1]} | Tail]) ->
    lists:flatten(Mod:format_error(Err) ++ io_lib:format("~n", [])) ++ compile_errors([{L, T1} | Tail]).

callable({Type, Default}, {Args, Acc}) ->
    case maps:find(Type, Args) of
        error when is_map_key(Default, Args) ->
            %% default is set, no overrides
            {Args, merge_callable(Type, lists:duplicate(length(Acc), [maps:get(Default, Args)]), Acc, [])};
        error ->
            %% no overrides, no default - most common case
            {Args, merge_callable(Type, [], Acc, [])};
        {ok, Overrides} when is_map_key(Default, Args) ->
            %% some overrides, and the default as well
            %% extend the Overrides array to expected size by adding default value
            Def = [maps:get(Default, Args)],
            Complete = Overrides ++ [Def || _ <- lists:seq(1, length(Acc) - length(Overrides))],
            {Args, merge_callable(Type, Complete, Acc, [])};
        {ok, NoDefault} ->
            %% no default, but some arguments are defined
            {Args, merge_callable(Type, NoDefault, Acc, [])}
    end.

merge_callable(_Type, [], Acc, Merged) ->
    lists:reverse(Merged) ++ Acc;
merge_callable(_Type, _, [], Merged) ->
    lists:reverse(Merged);
merge_callable(Type, [[H] | T], [HA | Acc], Merged) ->
    merge_callable(Type, T, Acc, [HA#{Type => H} | Merged]).

parse_code(Code) ->
    case lists:last(Code) of
        $. ->
            #{runner => Code};
        $} when hd(Code) =:= ${ ->
            % parse MFA tuple with added "."
            #{runner => parse_mfa_tuple(Code)};
        _ ->
            case file:read_file(Code) of
                {ok, Bin} ->
                    #{runner => parse_call_record(Bin)};
                Other ->
                    erlang:throw({parse, Code, Other})
            end
    end.

parse_mfa_tuple(Code) ->
    {ok, Scan, _} = erl_scan:string(Code ++ "."),
    {ok, Term} = erl_parse:parse_term(Scan),
    Term.

parse_call_record(Bin) ->
    binary_to_term(Bin).

parse_loop(Loop) ->
    case string:to_integer(Loop) of
        {Int, "M"} -> Int * 1000000;
        {Int, "K"} -> Int * 1000;
        {Int, []} -> Int;
        {Int, "G"} -> Int * 1000000000;
        _Other -> erlang:error({generic, "unsupported syntax for timed iteration count: " ++ Loop})
    end.

arguments() ->
    #{help =>
        "\nBenchmark timer:sleep(1):\n    erlperf 'timer:sleep(1).'\n"
        "Benchmark rand:uniform() vs crypto:strong_rand_bytes(2):\n    erlperf 'rand:uniform().' 'crypto:strong_rand_bytes(2).' --samples 10 --warmup 1\n"
        "Figure out concurrency limits:\n    erlperf 'code:is_loaded(local_udp).' --init 'code:ensure_loaded(local_udp).'\n"
        "Benchmark pg join/leave operations:\n    erlperf 'pg:join(s, foo, self()), pg:leave(s, foo, self()).' --init 'pg:start_link(s).'\n"
        "Timed benchmark for a single BIF:\n    erlperf 'erlang:unique_integer().' -l 1000000\n",
        arguments => [
            #{name => concurrency, short => $c, long => "-concurrency",
                help => "number of concurrently executed runner processes",
                type => {int, [{min, 1}, {max, 1024 * 1024 * 1024}]}},
            #{name => sample_duration, short => $d, long => "-duration",
                help => "single sample duration, milliseconds (1000)",
                type => {int, [{min, 1}]}},
            #{name => samples, short => $s, long => "-samples",
                help => "minimum number of samples to collect (3)",
                type => {int, [{min, 1}]}},
            #{name => loop, short => $l, long => "-loop",
                help => "timed mode (lower overhead) iteration count: 50, 100K, 200M, 3G"},
            #{name => warmup, short => $w, long => "-warmup",
                help => "number of samples to skip (0)",
                type => {int, [{min, 0}]}},
            #{name => cv, long => "-cv",
                help => "coefficient of variation",
                type => {float, [{min, 0.0}]}},
            #{name => verbose, short => $v, long => "-verbose",
                type => boolean, help => "print monitoring statistics"},
            #{name => code_path, long => "pa", type => string,
                action => append, help => "extra code path, see -pa erl documentation"},
            #{name => isolation, short => $i, long => "-isolated", type => boolean,
                help => "run benchmarks in an isolated environment (peer node)"},
            #{name => squeeze, short => $q, long => "-squeeze", type => boolean,
                help => "run concurrency test"},
            #{name => min, long => "-min",
                help => "start with this amount of processes (1)",
                type => {int, [{min, 1}]}},
            #{name => max, long => "-max",
                help => "do not exceed this number of processes",
                type => {int, [{max, erlang:system_info(process_limit) - 1000}]}},
            #{name => threshold, short => $t, long => "-threshold",
                help => "cv at least <threshold> samples should be less than <cv> to increase concurrency", default => 3,
                type => {int, [{min, 1}]}},
            #{name => init, long => "-init",
                help => "init code", nargs => 1, action => append},
            #{name => done, long => "-done",
                help => "done code", nargs => 1, action => append},
            #{name => init_runner, long => "-init_runner",
                help => "init_runner code", nargs => 1, action => append},
            #{name => init_all, long => "-init_all",
                help => "default init code for all runners"},
            #{name => done_all, long => "-done_all",
                help => "default done code for all runners"},
            #{name => init_runner_all, long => "-init_runner_all",
                help => "default init_runner code for all runners"},
            #{name => code,
                help => "code to test", nargs => nonempty_list, action => extend}
        ]}.

%%-------------------------------------------------------------------
%% Color output

-spec format(error | warning | info, string(), [term()]) -> ok.
format(Level, Format, Terms) ->
    io:format(color(Level, Format), Terms).

-define(RED, "\e[31m").
-define(MAGENTA, "\e[35m").
-define(END, "\e[0m~n").

color(error, Text) -> ?RED ++ Text ++ ?END;
color(warning, Text) -> ?MAGENTA ++ Text ++ ?END;
color(info, Text) -> Text.

% wrong usage
main_impl(_RunOpts, SqueezeOps, [_, _ | _]) when map_size(SqueezeOps) > 0 ->
    io:format("Multiple concurrency tests is not supported, run it one by one~n");

main_impl(RunOpts, SqueezeOpts, Codes) ->
    % verbose?
    {Pg, Monitor, Logger} =
        case maps:get(verbose, RunOpts, false) of
            true ->
                {ok, P} = pg:start_link(erlperf),
                {ok, Mon} = erlperf_monitor:start_link(),
                {ok, Log} = erlperf_file_log:start_link(group_leader()),
                {P, Mon, Log};
            false ->
                {undefined, undefined, undefined}
        end,
    try
        run_main(RunOpts, SqueezeOpts, Codes)
    after
        Logger =/= undefined andalso gen:stop(Logger),
        Monitor =/= undefined andalso gen:stop(Monitor),
        Pg =/= undefined andalso gen:stop(Pg)
    end.

%% low overhead mode
run_main(#{loop := Loop}, #{}, Codes) ->
    TimeUs = erlperf:benchmark(Codes, #{samples => Loop, sample_duration => undefined}, undefined),
    %% for presentation purposes, convert time to QPS
    %% Duration is fixed to 1 second here
    QPS = [Loop * 1000000 div T || T <- TimeUs],
    format_result(Codes, 1, QPS, [T * 1000 div Loop || T <- TimeUs]);

%% squeeze test: do not print "Relative" column as it's always 100%
% Code                         Concurrency   Throughput
% pg2:create(foo).                      14      9540 Ki
run_main(RunOpts, SqueezeOps, [Code]) when map_size(SqueezeOps) > 0 ->
    Duration = maps:get(sample_duration, RunOpts, 1000),
    {QPS, Con} = erlperf:run(Code, RunOpts, SqueezeOps),
    Timing = if QPS =:=0 -> infinity; true -> Duration * 1000000 div QPS * Con end,
    format_result([Code], Con, [QPS], [Timing]);

%% benchmark: don't print "Relative" column for a single sample
% erlperf 'timer:sleep(1).'
% Code               Concurrency   Throughput
% timer:sleep(1).              1          498
% --
% Code                         Concurrency   Throughput   Relative
% rand:uniform().                        1      4303 Ki       100%
% crypto:strong_rand_bytes(2).           1      1485 Ki        35%

run_main(RunOpts, _, Execs) ->
    Concurrency = maps:get(concurrency, RunOpts, 1),
    Duration = maps:get(sample_duration, RunOpts, 1000),
    Throughput = erlperf:benchmark(Execs, RunOpts, undefined),
    Timings = [if T =:= 0 -> infinity; true -> Duration * 1000000 div T * Concurrency end || T <- Throughput],
    format_result(Execs, Concurrency, Throughput, Timings).

format_result(Execs, Concurrency, Throughput, Timings) ->
    MaxQPS = lists:max(Throughput),
    Codes = [maps:get(runner, Code) || Code <- Execs],
    Zipped = lists:reverse(lists:keysort(2, lists:zip3(Codes, Throughput, Timings))),
    %% Columns: Code | Concurrency | Throughput | Time | Relative
    %% Code takes all the remaining width.
    MaxColumns = case io:columns() of {ok, C} -> C; _ -> 80 end,
    %% Space taken by all columns except code
    case Throughput of
        [_] ->
            %% omit "Rel" when there is one result
            MaxCodeLen = min(code_length(hd(Codes)) + 4, MaxColumns - 31),
            io:format("~*s     ||        QPS       Time~n", [-MaxCodeLen, "Code"]),
            io:format("~*s ~6b ~10s ~10s~n", [-MaxCodeLen, format_code(hd(Codes)), Concurrency,
                erlperf_file_log:format_number(hd(Throughput)), erlperf_file_log:format_duration(hd(Timings))]);
        [_|_] ->
            MaxCodeLen = min(lists:max([code_length(Code) || Code <- Codes]) + 4, MaxColumns - 37),
            io:format("~*s     ||        QPS       Time     Rel~n", [-MaxCodeLen, "Code"]),
            [io:format("~*s ~6b ~10s ~10s ~6b%~n", [-MaxCodeLen, format_code(Code), Concurrency,
                erlperf_file_log:format_number(QPS), erlperf_file_log:format_duration(Time), QPS * 100 div MaxQPS])
                || {Code, QPS, Time}  <- Zipped]
    end.

format_code(Code) when is_tuple(Code) ->
    lists:flatten(io_lib:format("~tp", [Code]));
format_code(Code) when is_tuple(hd(Code)) ->
    lists:flatten(io_lib:format("[~tp, ...]", [hd(Code)]));
format_code(Code) ->
    Code.

code_length(Code) ->
    length(format_code(Code)).
