erlperf
=====

Erlang Performance & Benchmarking Suite.
Simple way to say "this code is faster than that one".

Build:

```bash
    $ rebar3 as prod escriptize
```

# TL; DR

Find out how many times per second a function can be run  (beware of shell escaping your code!):

```bash
    $ ../erlperf 'rand:uniform().'
    Code                    ||        QPS     Rel
    rand:uniform().          1    9798 Ki    100%
```

Run four processes executing `rand:uniform()` in a tight loop, and see that code is indeed
concurrent:

```bash
    $ ./erlperf 'rand:uniform().' -c 4
    Code                    ||        QPS     Rel
    rand:uniform().          4   28596 Ki    100%
```

Benchmark one function vs another, taking average of 10 seconds and skipping first second:

```bash
    $ ./erlperf 'rand:uniform().' 'crypto:strong_rand_bytes(2).' --samples 10 --warmup 1
    Code                         Concurrency   Throughput   Relative
    rand:uniform().                        1      4303 Ki       100%
    crypto:strong_rand_bytes(2).           1      1485 Ki        35%
```

Run a function passing the state into the next iteration. This code demonstrates performance difference
between `rand:uniform_s` with state passed explicitly, and `rand:uniform` reading state from the process
dictionary:

```bash
    $ ./erlperf 'r(_Init, S) -> {_, NS} = rand:uniform_s(S), NS.' --init_runner 'rand:seed(exsss).' 'r() -> rand:uniform().'
    Code                                                    ||        QPS       Time     Rel
    r(_Init, S) -> {_, NS} = rand:uniform_s(S), NS.          1   20272 Ki      49 ns    100%
    r() -> rand:uniform().                                   1   15081 Ki      66 ns     74%
```

Squeeze mode: 
measure how concurrent your code is. In the example below, `code:is_loaded/1` is implemented as
`gen_server:call`, and all calculations are done in a single process. It is still possible to
squeeze a bit more from a single process by putting work into the queue from multiple runners,
therefore the example may show higher concurrency.

```bash
    $ ./erlperf 'code:is_loaded(local_udp).' --init 'code:ensure_loaded(local_udp).' --squeeze
    Code                           ||        QPS
    code:is_loaded(local_udp).      1     614 Ki
```

Start a server (`pg` scope in this example), use it in benchmark, and shut down after:

```bash
    $ ./erlperf 'pg:join(scope, group, self()), pg:leave(scope, group, self()).' --init 'pg:start_link(scope).' --done 'gen_server:stop(scope).'
    Code                                                                   ||        QPS     Rel
    pg:join(scope, group, self()), pg:leave(scope, group, self()).          1     321 Ki    100%
```

Run the same code with different arguments, returned from `init_runner` function:

```bash
    $ ./erlperf 'runner(X) -> timer:sleep(X).' --init_runner '1.' 'runner(X) -> timer:sleep(X).' --init_runner '2.'
    Code                                 ||        QPS     Rel
    runner(X) -> timer:sleep(X).          1        492    100%
    runner(Y) -> timer:sleep(Y).          1        331     67%
```
    
Determine how many times a process can join/leave pg2 group on a single node:

```bash
    $ ./erlperf 'ok = pg2:join(g, self()), ok = pg2:leave(g, self()).' --init 'pg2:create(g).'
    Code                                                         ||        QPS     Rel
    ok = pg2:join(g, self()), ok = pg2:leave(g, self()).          1      64253    100%
```

Compare `pg` with `pg2` running two nodes (note the `-i` argument spawning an extra node to
run benchmark in):

```bash
    ./erlperf 'ok = pg2:join(g, self()), ok = pg2:leave(g, self()).' --init 'pg2:create(g).' 'ok = pg:join(g, self()), ok = pg:leave(g, self()).' --init 'pg:start(pg).' -i
    Code                                                         ||        QPS     Rel
    ok = pg:join(g, self()), ok = pg:leave(g, self()).            1     235 Ki    100%
    ok = pg2:join(g, self()), ok = pg2:leave(g, self()).          1       1817      0%
```

Watch the progress of your test running (use -v option) with extra information: scheduler utilisation, dirty CPU & IO
schedulers, number of running processes, ports, ETS tables, and memory consumption. Last column is the job throughput.
When there are multiple jobs, multiple columns are printed.

```bash
    $ ./erlperf 'rand:uniform().' -q -v
    
    YYYY-MM-DDTHH:MM:SS-oo:oo  Sched   DCPU    DIO    Procs    Ports     ETS Mem Total  Mem Proc   Mem Bin   Mem ETS  <0.92.0>
    2019-06-21T13:25:21-07:00  11.98   0.00   0.47       52        3      20  32451 Kb   4673 Kb    179 Kb    458 Kb    3761 Ki
    2019-06-21T13:25:22-07:00  12.57   0.00   0.00       52        3      20  32702 Kb   4898 Kb    201 Kb    460 Kb    4343 Ki
    <...>
    2019-06-21T13:25:54-07:00 100.00   0.00   0.00       63        3      20  32839 Kb   4899 Kb    203 Kb    469 Kb   14296 Ki
    2019-06-21T13:25:55-07:00 100.00   0.00   0.00       63        3      20  32814 Kb   4969 Kb    201 Kb    469 Kb   13810 Ki
    2019-06-21T13:25:56-07:00 100.00   0.00   0.00       63        3      20  32809 Kb   4964 Kb    201 Kb    469 Kb   13074 Ki
    Code                ||        QPS
    rand:uniform().      8   14918 Ki
```

Command-line benchmarking does not save results anywhere. It is designed to provide a quick answer to the question
"is that piece of code faster".

## Minimal overhead mode
Since 2.0, `erlperf` includes "low overhead" mode. It cannot be used for continuous benchmarking. In this mode
runner code is executed specified amount of times in a tight loop:

```bash
    ./erlperf 'rand:uniform().' 'rand:uniform(1000).' -l 10M
    Code                        ||        QPS       Time     Rel
    rand:uniform().              1   16319 Ki      61 ns    100%
    rand:uniform(1000).          1   15899 Ki      62 ns     97%
```

This mode effectively runs following code: `loop(0) -> ok; loop(Count) -> rand:uniform(), loop(Count - 1).`
Continuous mode adds 1-2 ns to each iteration.

# Benchmarking existing application
`erlperf` can be used to measure performance of your application running in production, or code that is stored
on disk.

## Running with existing codebase
Use `-pa` argument to add extra code path. Example:
```bash
    $ ./erlperf 'argparse:parse([], #{}).' -pa _build/test/lib/argparse/ebin
    Code                             ||        QPS     Rel
    argparse:parse([], #{}).          1     859 Ki    100%
```

If you need to add multiple released applications, supply `ERL_LIBS` environment variable instead:
```bash
    $ ERL_LIBS="_build/test/lib" erlperf 'argparse:parse([], #{}).'
    Code                             ||        QPS     Rel
    argparse:parse([], #{}).          1     843 Ki    100%
```

## Usage in production
It is possible to use `erlperf` to benchmark a running application (even in production, assuming necessary safety
precautions). To achieve this, add `erlperf` as a dependency, and use remote shell:

```bash
    # run a mock production node with `erl -sname production`
    # connect a remote shell to the production node
    erl -remsh production
    (production@max-au)3> erlperf:run(timer, sleep, [1]).
    488
```

## Continuous benchmarking
You can run a job continuously, to examine performance gains or losses while doing 
hot code reload. This process is designed to help during development and testing stages, 
allowing to quickly notice performance regressions.

Example source code:
```erlang
    -module(mymod).
    -export([do/1]).
    do(Arg) -> timer:sleep(Arg).
```
 
Example below assumes you have `erlperf` application started (e.g. in a `rebar3 shell`)

```erlang
    % start a logger that prints VM monitoring information
    > {ok, Logger} = erlperf_file_log:start_link(group_leader()).
    {ok,<0.235.0>}
    
    % start a job that will continuously benchmark mymod:do(),
    %  with initial concurrency 2.
    > JobPid = erlperf:start(#{init_runner => "rand:uniform(10).", 
        runner => "runner(Arg) -> mymod:do(Arg)."}, 2).
    {ok,<0.291.0>}
    
    % increase concurrency to 4
    > erlperf_job:set_concurrency(JobPid, 4).
    ok.
    
    % watch your job performance

    % modify your application code, 
    % set do(Arg) -> timer:sleep(2*Arg), do hot code reload
    > c(mymod).
    {module, mymod}.
    
    % see that after hot code reload throughput halved!
```

# Reference Guide

## Terms

* **runner**: code that gets continuously executed
* **init**: code that runs one when the job starts (for example, start some registered process or create an ETS table)
* **done**: code that runs when the job is about to stop (used for cleanup, e.g. stop some registered process)
* **init_runner**: code that is executed in every runner process (e.g. add something to process dictionary)
* **job**: single instance of the running benchmark (multiple runners)
* **concurrency**: how many processes are running concurrently, executing *runner* code
* **throughput**: total number of calls per sampling interval (for all concurrent processes)
* **cv**: coefficient of variation, the ratio of the standard deviation to the mean. Used to stop the concurrency 
(squeeze) test, the lower the *cv*, the longer it will take to stabilise and complete the test

## Using `erlperf` from `rebar3 shell` or `erl` REPL
Supported use-cases:
 * single run for MFA: ```erlperf:run({rand, uniform, [1000]}).``` or ```erlperf:run(rand, uniform, []).```
 * anonymous function: ```erlperf:run(fun() -> rand:uniform(100) end).```
 * anonymous function with an argument: ```erlperf:run(fun(Init) -> io_lib:format("~tp", [Init]) end).```
 * source code: ```erlperf:run("runner() -> rand:uniform(20).").```
 * (experimental) call chain: ```erlperf:run([{rand, uniform, [10]}, {erlang, node, []}]).```,
     see [recording call chain](#recording-call-chain). Call chain may contain only complete
     MFA tuples and cannot be mixed with functions.
 
Startup and teardown 
 * init, done and init_runner are supported (there is no done_runner,
 because it is never stopped in a graceful way)
 * init_runner and done may be defined with arity 0 and 1 (in the latter case,
 result of init/0 passed as an argument)
 * runner can be of arity 0, 1 (accepting init_runner return value) or 2 (first
 argument is init_runner return value, and second is state passed between runner invocations)
 
Example with mixed MFA:
```erlang
   erlperf:run(
       #{
           runner => fun(Arg) -> rand:uniform(Arg) end,
           init => 
               {pg, start_link, []},
           init_runner =>
               fun ({ok, Pid}) -> 
                   {total_heap_size, THS} = erlang:process_info(Pid, total_heap_size),
                   THS
               end,
           done => fun ({ok, Pid}) -> gen_server:stop(Pid) end
       }
   ).
``` 
 
Same example with source code:
```erlang
erlperf:run(
    #{
        runner => "runner(Max) -> rand:uniform(Max).",
        init => "init() -> pg:start_link().",
        init_runner => "init_runner({ok, Pid}) ->
            {total_heap_size, THS} = erlang:process_info(Pid, total_heap_size),
            THS.",
        done => "done({ok, Pid}) -> gen_server:stop(Pid)."
    }       
).
```

## Measurement options
Benchmarking is done by counting number of *runner* iterations done over
a specified period of time (**sample_duration**). 
By default, erlperf performs no **warmup** cycle, then takes 3 consecutive 
**samples**, using **concurrency** of 1 (single runner). It is possible 
to tune this behaviour by specifying run_options:
```erlang
    erlperf:run({erlang, node, []}, #{concurrency => 2, samples => 10, warmup => 1}).
```

Next example takes 10 samples with 100 ms duration. Note that throughput is reported
per *sample_duration*: if you shorten duration in half, throughput report will also be
halved:

```bash
    $ ./erlperf 'rand:uniform().' -d 100 -s 20
    Code                    ||        QPS     Rel
    rand:uniform().          1     970 Ki    100%
    $ ./erlperf 'rand:uniform().' -d 200 -s 20
    Code                    ||        QPS     Rel
    rand:uniform().          1    1973 Ki    100%
```

## Concurrency test (squeeze)
Sometimes it's necessary to measure code running multiple concurrent
processes, and find out when it saturates the node. It can be used to
detect bottlenecks, e.g. lock contention, single dispatcher process
bottleneck etc.. Example (with maximum concurrency limited to 50):

```erlang
    > erlperf:run({code, is_loaded, [local_udp]}, #{warmup => 1}, #{max => 50}).
    {1284971,7}
```

In this example, 7 concurrent processes were able to squeeze 1284971 calls per second
for `code:is_loaded(local_udp)`.

## Benchmarking overhead
Benchmarking overhead varies depending on ERTS version and the way runner code is supplied. See the example: 

```erlang
    (erlperf@max-au)7> erlperf:benchmark([
            #{runner => "runner(X) -> is_float(X).", init_runner=>"2."}, 
            #{runner => {erlang, is_float, [2]}},
            #{runner => fun (X) -> is_float(X) end, init_runner => "2."}], 
        #{}, undefined).
    [105824351,66424280,5057372]
```

This difference is caused by the ERTS itself: running compiled code (first variant) with OTP 25 is 
two times faster than applying a function, and 20 times faster than repeatedly calling anonymous `fun`. Use
the same invocation method to get a relevant result.

Absolute benchmarking overhead may be significant for very fast functions taking just a few nanoseconds.
Use "low overhead mode" for such occasions.

## Experimental: recording call chain
This experimental feature allows capturing a sequence of calls as a list of
`{Module, Function, [Args]}`. The trace can be supplied as a `runner` argument
to `erlperf` for benchmarking purposes:

```erlang
    > f(Trace), Trace = erlperf:record(pg, '_', '_', 1000).
    ...
    
    % for things working with ETS, isolation is recommended
    > erlperf:run(#{runner => Trace}, #{isolation => #{}}).
    ...
    
    % Trace can be saved to file before executing:
    > file:write("pg.trace", term_to_binary(Trace)).
    
    % run the saved trace
    > {ok, Bin} = file:read_file("pg.trace"),
    > erlperf:run(#{runner => binary_to_term(Trace)}).
```

It's possible to create a Common Test testcase using recorded samples.
Just put the recorded file into xxx_SUITE_data:
```erlang
    benchmark_check(Config) ->
        {ok, Bin} = file:read_file(filename:join(?config(data_dir, Config), "pg.trace")),
        QPS = erlperf:run(#{runner => binary_to_term(Bin)}),
        ?assert(QPS > 500). % catches regression for QPS falling below 500
```

## Experimental: starting jobs in a cluster

It's possible to run a job on a separate node in the cluster.

```erlang
    % watch the entire cluster (printed to console)
    (node1@host)> {ok, _} = erlperf_history:start_link().
    {ok,<0.213.0>}
    (node1@host)> {ok, ClusterLogger} = erlperf_cluster_monitor:start_link(group_leader(), [sched_util, jobs]).
    {ok, <0.216.0>}
    
    % also log cluster-wide reports to file (jobs & sched_util)
    (node1@host)> {ok, FileLogger} = erlperf_cluster_monitor:start_link("/tmp/cluster", [time, sched_util, jobs]).
    {ok, <0.223.0>}

    % run the benchmarking process in a different node of your cluster
    (node1@host)> rpc:call('node2@host', erlperf, run, [#{runner => {rand, uniform, []}}]).
```

Cluster-wide monitoring will reflect changes accordingly.


# Implementation details
Starting with 2.0, `erlperf` uses call counting for continuous benchmarking purposes. This allows
the tightest possible loop without extra runtime calls. Running
`erlperf 'rand:uniform().' --init '1'. --done '2.' --init_runner '3.'` results in creating,
compiling and loading a module with this source code:

```erlang
    -module(unique_name).
    -export([init/0, init_runner/0, done/0, run/0]).

    init() ->
        1.

    init_runner() ->
        3.

    done() ->
        2.

    run() ->
        runner(), 
        run().

    runner() ->
        rand:uniform().
```

Number of `run/0` calls per second is reported as throughput. Before 2.0, `erlperf` 
used `atomics` to maintain a counter shared between all runner processes, introducing
unnecessary BIF call overhead. 

Low-overhead mode tightens it even further, turning runner into this function:
```erlang
runner(0) ->
    ok;
runner(Count) ->
    rand:uniform(),
    runner(Count - 1).
```