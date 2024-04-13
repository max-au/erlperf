%%% @copyright (C) 2019-2023, Maxim Fedorov
%%% @doc
%%% Command line interface adapter.
%%%
%%% Exports functions to format {@link erlperf:benchmark/3} output
%%% in the same way as command line interface.
%%%
%%% Example:
%%% ```
%%% #!/usr/bin/env escript
%%%  %%! +pc unicode -pa /home/max-au/git/max-au/erlperf/_build/default/lib/erlperf/ebin
%%% -mode(compile).
%%%
%%% main(_) ->
%%%     Report = erlperf:benchmark([
%%%         #{runner => fun() -> rand:uniform(10) end},
%%%         #{runner => {rand, mwc59, [1]}}
%%%     ], #{report => full}, undefined),
%%%     Out = erlperf_cli:format(Report, #{format => extended, viewport_width => 120}),
%%%     io:format(Out),
%%%     halt(0).
%%% '''
%%% Running the script produces following output:
%%% ```
%%% $ ./bench
%%% Code                                                ||   Samples       Avg   StdDev    Median      P99  Iteration    Rel
%%% {rand,mwc59,[1]}                                     1         3  80515 Ki    0.59%  80249 Ki 81067 Ki      12 ns   100%
%%% #Fun<bench__escript__1674__432325__319865__16.0.     1         3  15761 Ki    0.48%  15726 Ki 15847 Ki      63 ns    20%
%%% '''
-module(erlperf_cli).
-author("maximfca@gmail.com").

%% Public API for escript-based benchmarks
-export([
    format/2,
    main/1
]).

-type format_options() :: #{
    viewport_width => pos_integer(),
    format => basic | extended | full
}.
%% Defines text report format.
%%
%% <ul>
%%   <li>`format':
%%     <ul>
%%       <li>`basic': default format containing only average throughput per `sample_duration'
%%          and average runner runtime</li>
%%       <li>`extended': includes median, p99 and other metrics(default for 10 and more
%%          samples)</li>
%%       <li>`full': includes system information in addition to `extended' output</li>
%%     </ul>
%%     See overview for the detailed description</li>
%%   <li>`viewport_width': how wide the report can be, defaults to {@link io:columns/0}.
%%       Falls back to 80 when terminal does not report width.</li>
%% </ul>

-export_type([format_options/0]).

%% @doc
%% Formats result produced by {@link erlperf:benchmark/3}.
%%
%% Requires full report. Does not accept basic or extended variants.
-spec format(Reports, Options) -> iolist() when
    Reports :: [erlperf:report()],
    Options :: format_options().
format(Reports, Options) ->
    Format =
        case maps:find(format, Options) of
            {ok, F} ->
                F;
            error ->
                %% if format is not specified, choose between basic and extended
                %% based on amount of samples collected. Extended report does
                %% not make much sense for 3 samples.
                case maps:find(samples, maps:get(result, hd(Reports))) of
                    {ok, Samples} when length(Samples) >= 10 ->
                        extended;
                    _ ->
                        basic
                end
        end,
    Width = maps:get(viewport_width, Options, viewport_width()),
    %% if any of the reports has "sleep" set to busy_wait, write a warning
    Prefix =
        case lists:any(fun (#{sleep := busy_wait}) -> true; (_) -> false end, Reports) of
            true ->
                color(warning, io_lib:format("Timer accuracy problem detected, results may be inaccurate~n", []));
            false ->
                ""
        end,
    %%
    Prefix ++ format_report(Format, Reports, Width).

%%-------------------------------------------------------------------
%% Internal implementation

%% @private
%% Used from escript invocation
-spec main([string()]) -> no_return().
main(Args) ->
    Prog = #{progname => "erlperf"},
    try
        ParsedOpts = args:parse(Args, arguments(), Prog),

        Verbose = maps:get(verbose, ParsedOpts, false),

        %% turn off logger unless verbose output is requested
        Verbose orelse
            logger:add_primary_filter(suppress_sasl, {
                fun(#{meta := #{error_logger := #{tag := Tag}}}, _) when Tag =:= error; Tag =:= error_report ->
                        stop;
                    (_, _) ->
                        ignore
                end, ok}),

        %% timed benchmarking is not compatible with many options, and may have "loop" written as 100M, 100K
        {RunOpts0, ConcurrencyTestOpts} = determine_mode(ParsedOpts),

        %% add code paths
        [case code:add_path(P) of true -> ok; {error, Error} -> erlang:error({add_path, {P,Error}}) end
            || P <- maps:get(code_path, ParsedOpts, [])],

        %% find all runners
        Code0 = [parse_code(C) || C <- maps:get(code, ParsedOpts)],
        %% find associated init, init_runner, done
        {_, Codes} = lists:foldl(fun callable/2, {ParsedOpts, Code0},
            [{init, init_all}, {init_runner, init_runner_all}, {done, done_all}]),

        %% when isolation is requested, the node must be distributed
        RunOpts = case is_map_key(isolation, ParsedOpts) of
                      true ->
                          erlang:is_alive() orelse start_distribution(),
                          RunOpts0#{isolation => #{}};
                      false ->
                          RunOpts0
                  end,

        FormatOpts = case maps:find(report, ParsedOpts) of
                         {ok, Fmt1} ->
                             #{format => Fmt1};
                         error ->
                             #{}
                     end,
        %% do the actual run
        Results = benchmark(Codes, RunOpts#{report => full}, ConcurrencyTestOpts, Verbose),
        %% format results
        Formatted = format(Results, FormatOpts#{viewport_width => viewport_width()}),
        io:format(Formatted)
    catch
        error:{args, Reason} ->
            Fmt = args:format_error(Reason, arguments(), Prog),
            format(info, "Error: ~s", [Fmt]);
        throw:{parse, FunName, Other} ->
            format(error, "Unable to read file named '~s' (expected to contain call chain recording)~nReason: ~p\n"
                "Did you forget to end your function with period? (dot)~n", [FunName, Other]);
        error:{add_path, {Path, Error}} ->
            format(error, "Error adding code path ~s: ~p~n", [Path, Error]);
        error:{generic, Error} ->
            format(error, "Error: ~s~n", [Error]);
        error:{loop, Option} ->
            format(error, "Timed benchmarking is not compatible with --~s option~n", [Option]);
        error:{concurrency, Option} ->
            format(error, "Concurrency estimation is not compatible with --~s option~n", [Option]);
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

%% timed mode
determine_mode(#{loop := Loop} = ParsedOpts) ->
    [erlang:error({loop, Option}) || Option <-
        [concurrency, sample_duration, warmup, cv, concurrency_estimation], is_map_key(Option, ParsedOpts)],
    RunOpts = maps:with([samples], ParsedOpts),
    {RunOpts#{sample_duration => {timed, parse_loop(Loop)}}, undefined};

%% concurrency estimation mode
determine_mode(#{concurrency_estimation := true} = ParsedOpts) ->
    [erlang:error({concurrency, Option}) || Option <-
        [concurrency], is_map_key(Option, ParsedOpts)],
    length(maps:get(code, ParsedOpts)) > 1 andalso
        erlang:error({generic, "Parallel concurrency estimation runs are not supported~n"}),
    RunOpts = maps:with([sample_duration, samples, warmup, cv], ParsedOpts),
    {RunOpts, maps:with([min, max, threshold], ParsedOpts)};

%% continuous mode
determine_mode(ParsedOpts) ->
    RunOpts = maps:with([concurrency, sample_duration, samples, warmup, cv], ParsedOpts),
    {RunOpts, undefined}.

%% wrapper to ensure verbose output
benchmark(Codes, RunOpts, ConcurrencyTestOpts, false) ->
    erlperf:benchmark(Codes, RunOpts, ConcurrencyTestOpts);
benchmark(Codes, RunOpts, ConcurrencyTestOpts, true) ->
    {ok, Pg} = pg:start_link(erlperf),
    {ok, Monitor} = erlperf_monitor:start_link(),
    {ok, Logger} = erlperf_file_log:start_link(),
    try
        erlperf:benchmark(Codes, RunOpts, ConcurrencyTestOpts)
    after
        gen:stop(Logger),
        gen:stop(Monitor),
        gen:stop(Pg)
    end.

start_distribution() ->
    Node = list_to_atom(lists:concat(["erlperf-", erlang:unique_integer([positive]), "-", os:getpid()])),
    {ok, _} = net_kernel:start([Node, shortnames]).

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
        "\nFull documentation available at: https://hexdocs.pm/erlperf/\n"
        "\nBenchmark timer:sleep(1):\n    erlperf 'timer:sleep(1).'\n"
        "Benchmark rand:uniform() vs crypto:strong_rand_bytes(2):\n    erlperf 'rand:uniform().' 'crypto:strong_rand_bytes(2).' --samples 10 --warmup 1\n"
        "Figure out concurrency limits:\n    erlperf 'application_controller:is_running(kernel).' -q'\n"
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
            #{name => report, short => $r, long => "-report",
                help => "report verbosity, full adds system information",
                type => {atom, [basic, extended, full]}},
            #{name => cv, long => "-cv",
                help => "coefficient of variation",
                type => {float, [{min, 0.0}]}},
            #{name => verbose, short => $v, long => "-verbose",
                type => boolean, help => "print monitoring statistics"},
            #{name => code_path, long => "pa", type => string,
                action => append, help => "extra code path, see -pa erl documentation"},
            #{name => isolation, short => $i, long => "-isolated", type => boolean,
                help => "run benchmarks in an isolated environment (peer node)"},
            #{name => concurrency_estimation, short => $q, long => "-squeeze", type => boolean,
                help => "run concurrency estimation test"},
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
                help => "init code, see erlperf_job documentation for details", nargs => 1, action => append},
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

%% Report formatter
format_report(full, [#{system := System} | _] = Reports, Width) ->
    [format_system(System), format_report(extended, Reports, Width)];

format_report(extended, Reports, Width) ->
    Sorted = sort_by(Reports),
    #{result := #{average := MaxAvg}} = hd(Sorted),
    Header = ["Code", "   ||", "  Samples", "      Avg", "  StdDev", "   Median", "     P99", " Iteration", "   Rel"],
    Data = [format_report_line(MaxAvg, ReportLine, extended) || ReportLine <- Sorted],
    format_table(remove_relative_column([Header | Data]), Width);

format_report(basic, Reports, Width) ->
    Sorted = sort_by(Reports),
    #{result := #{average := MaxAvg}} = hd(Sorted),
    Header = ["Code", "       ||", "       QPS", "      Time", "  Rel"],
    Data0 = [format_report_line(MaxAvg, ReportLine, basic) || ReportLine <- Sorted],
    %% remove columns that should not be displayed in basic mode
    Data = [[C1, C2, C3, C4, C5] || [C1, C2, _, C3, _, _, _, C4, C5] <- Data0],
    format_table(remove_relative_column([Header | Data]), Width).

sort_by([#{mode := timed} | _] = Reports) ->
    lists:sort(fun (#{result := #{average := L}}, #{result := #{average := R}}) -> L < R end, Reports);
sort_by([#{mode := _} | _] = Reports) ->
    lists:sort(fun (#{result := #{average := L}}, #{result := #{average := R}}) -> L > R end, Reports).

remove_relative_column([H, D]) ->
    [lists:droplast(H), lists:droplast(D)];
remove_relative_column(HasRelative) ->
    HasRelative.

format_report_line(MaxAvg, #{mode := timed, code := #{runner := Code}, result := #{average := Avg, stddev := StdDev,
    iteration_time := IterationTime, p99 := P99, median := Median, samples := Samples},
    run_options := #{concurrency := Concurrency}}, ReportFormat) ->
    [
        format_code(Code),
        integer_to_list(Concurrency),
        integer_to_list(length(Samples)),
        if ReportFormat =:= basic -> erlperf_file_log:format_number(erlang:round(1000000000 / IterationTime));
            true ->erlperf_file_log:format_duration(erlang:round(Avg * 1000)) end,
        io_lib:format("~.2f%", [StdDev * 100 / Avg]),
        erlperf_file_log:format_duration(Median * 1000), %% convert from ms to us
        erlperf_file_log:format_duration(P99 * 1000), %% convert from ms to us
        erlperf_file_log:format_duration(IterationTime), %% already in us
        integer_to_list(erlang:round(MaxAvg * 100 / Avg)) ++ "%"
    ];

format_report_line(MaxAvg, #{code := #{runner := Code}, result := #{average := Avg, stddev := StdDev,
    iteration_time := IterationTime, p99 := P99, median := Median, samples := Samples},
    run_options := #{concurrency := Concurrency}}, _ReportFormat) ->
    [
        format_code(Code),
        integer_to_list(Concurrency),
        integer_to_list(length(Samples) - 1),
        erlperf_file_log:format_number(erlang:round(Avg)),
        io_lib:format("~.2f%", [StdDev * 100 / Avg]),
        erlperf_file_log:format_number(Median),
        erlperf_file_log:format_number(P99),
        erlperf_file_log:format_duration(IterationTime),
        integer_to_list(erlang:round(Avg * 100 / MaxAvg)) ++ "%"
    ].

%% generic table formatter routine, accepting list of lists
format_table([Header | Data] = Rows, Width) ->
    %% find the longest string in each column
    HdrWidths = [string:length(H) + 1 || H <- Header],
    ColWidths = lists:foldl(
        fun (Row, Acc) ->
            [max(string:length(D) + 1, Old) || {D, Old} <- lists:zip(Row, Acc)]
        end, HdrWidths, Data),
    %% reserved (non-adjustable) columns
    Reserved = lists:sum(tl(ColWidths)),
    FirstColWidth = min(hd(ColWidths), Width - Reserved),
    Format = "~*s" ++ lists:concat([io_lib:format("~~~bs", [W]) || W <- tl(ColWidths)]) ++ "~n",
    %% just format the table
    [io_lib:format(Format, [-FirstColWidth | Row]) || Row <- Rows].

%% detects terminal width (characters) to shorten long output lines
viewport_width() ->
    case io:columns() of {ok, C} -> C; _ -> 80 end.

format_code(Code) when is_tuple(Code) ->
    lists:flatten(io_lib:format("~tp", [Code]));
format_code(Code) when is_tuple(hd(Code)) ->
    lists:flatten(io_lib:format("[~tp, ...]", [hd(Code)]));
format_code(Code) when is_function(Code) ->
    lists:flatten(io_lib:format("~tp", [Code]));
format_code(Code) when is_list(Code) ->
    Code;
format_code(Code) when is_binary(Code) ->
    binary_to_list(Code).

format_system(#{os := OSType, system_version := SystemVsn} = System) ->
    OS = io_lib:format("OS : ~s~n", [format_os(OSType)]),
    CPU = if is_map_key(cpu, System) -> io_lib:format("CPU: ~s~n", [maps:get(cpu, System)]); true -> "" end,
    VM = io_lib:format("VM : ~s~n~n", [SystemVsn]),
    [OS, CPU, VM].

format_os({unix, freebsd}) -> "FreeBSD";
format_os({unix, darwin}) -> "MacOS";
format_os({unix, linux}) -> "Linux";
format_os({win32, nt}) -> "Windows";
format_os({Family, OS}) -> lists:flatten(io_lib:format("~s/~s", [Family, OS])).