# erlperf

[![Build Status](https://github.com/max-au/erlperf/actions/workflows/erlang.yml/badge.svg?branch=master)](https://github.com/max-au/erlperf/actions) [![Hex.pm](https://img.shields.io/hexpm/v/erlperf.svg)](https://hex.pm/packages/erlperf) [![Hex Docs](https://img.shields.io/badge/hex-docs-blue.svg)](https://hexdocs.pm/erlperf)

Erlang Performance & Benchmarking Suite.
Simple way to say "this code is faster than that one". See the detailed
reference for `erlperf` and `erlperf_job` modules.

Build (tested with OTP 23, 24, 25):

```bash
    $ rebar3 as prod escriptize
```

## Command Line examples
Command-line benchmarking does not save results anywhere. It is designed to provide a quick answer to the question
"how fast the code is". Beware of the shell escaping your code in an unpredictable way!

Examples:

1. Run a single process iterating `rand:uniform()` in a tight loop for 3 seconds,
printing **average iterations per second** (~14 millions) and an average time
to run a single iteration (71 ns).

```bash
    $ ./erlperf 'rand:uniform().'
    Code                    ||        QPS       Time
    rand:uniform().          1   13942 Ki      71 ns
```

2. Run four processes doing this same concurrently.

```bash
    $ ./erlperf 'rand:uniform().' -c 4
    Code                    ||        QPS       Time
    rand:uniform().          4   39489 Ki     100 ns
```

3. Benchmark `rand:uniform()` vs `crypto:strong_rand_bytes(2)` for 10 seconds, adding
an extra second to warm up the algorithms.

```bash
    $ ./erlperf 'rand:uniform().' 'crypto:strong_rand_bytes(2).' --samples 10 --warmup 1
    Code                                 ||        QPS       Time     Rel
    rand:uniform().                       1   15073 Ki      66 ns    100%
    crypto:strong_rand_bytes(2).          1    1136 Ki     880 ns      7%
```

4. Run a function passing the state into the next iteration. This code demonstrates performance difference
between `rand:uniform_s` with state passed explicitly, and `rand:uniform` reading state from the process
dictionary.

```bash
    $ ./erlperf 'r(_, Seed) -> {_, Next} = rand:uniform_s(Seed), Next.' \
                --init_runner 'rand:seed(exsss).' \
                'r() -> rand:uniform().'
    Code                                                    ||        QPS       Time     Rel
    r(_Init, S) -> {_, NS} = rand:uniform_s(S), NS.          1   20272 Ki      49 ns    100%
    r() -> rand:uniform().                                   1   15081 Ki      66 ns     74%
```

5. Estimate `code:is_loaded/1` concurrency characteristics. This function is implemented as
`gen_server:call`, and all calculations are done in a single process. It is still possible to
squeeze a bit more from a single process by putting work into the queue from multiple runners.

```bash
    $ ./erlperf 'code:is_loaded(local_udp).' --init 'code:ensure_loaded(local_udp).' --squeeze
    Code                               ||        QPS       Time
    code:is_loaded(local_udp).          5     927 Ki    5390 ns
```

6. Start a server (`pg` scope in this example), use it in benchmark, and shut down after.

```bash
    $ ./erlperf 'pg:join(scope, group, self()), pg:leave(scope, group, self()).' \
                --init 'pg:start_link(scope).' --done 'gen_server:stop(scope).'
    Code                                                                   ||        QPS       Time
    pg:join(scope, group, self()), pg:leave(scope, group, self()).          1     336 Ki    2978 ns
```

7. Run the same code with different arguments, returned from `init_runner` function. Note the trick
of adding extra spaces in the source code to know which code is where.

```bash
    $ ./erlperf 'runner(X) -> timer:sleep(X).' --init_runner '1.' \
                '  runner(X) -> timer:sleep(X).' --init_runner '2.'
    Code                                 ||        QPS       Time     Rel
    runner(X) -> timer:sleep(X).          1        498    2008 us    100%
      runner(X) -> timer:sleep(X).        1        332    3012 us     66%
```
    
8. Determine how many times a process can join/leave pg2 group on a single node (requires OTP 23
or older, as pg2 is removed in later versions).

```bash
    $ ./erlperf 'ok = pg2:join(g, self()), ok = pg2:leave(g, self()).' --init 'pg2:create(g).'
    Code                                                         ||        QPS       Time
    ok = pg2:join(g, self()), ok = pg2:leave(g, self()).          1      64021   15619 ns
```

9. Compare `pg` with `pg2` running two nodes (note the `-i` argument spawning an isolated extra node to
run benchmark in):

```bash
    ./erlperf 'ok = pg2:join(g, self()), ok = pg2:leave(g, self()).' --init 'pg2:create(g).' \
              'ok = pg:join(g, self()), ok = pg:leave(g, self()).' --init 'pg:start(pg).' -i
    Code                                                         ||        QPS       Time     Rel
    ok = pg:join(g, self()), ok = pg:leave(g, self()).            1     241 Ki    4147 ns    100%
    ok = pg2:join(g, self()), ok = pg2:leave(g, self()).          1       1415     707 us      0%
```

10. Watch the progress of your test running (`-v` option) with extra information: scheduler utilisation, dirty CPU & IO
schedulers, number of running processes, ports, ETS tables, and memory consumption. Last column is the job throughput.
When there are multiple jobs, multiple columns are printed.

```bash
    $ ./erlperf 'rand:uniform().' -q -v
    
    YYYY-MM-DDTHH:MM:SS-oo:oo  Sched   DCPU    DIO    Procs    Ports     ETS Mem Total  Mem Proc   Mem Bin   Mem ETS   <0.80.0>
    2022-04-08T22:42:55-07:00   3.03   0.00   0.32       42        3      20  30936 Kb   5114 Kb    185 Kb    423 Kb   13110 Ki
    2022-04-08T22:42:56-07:00   3.24   0.00   0.00       42        3      20  31829 Kb   5575 Kb    211 Kb    424 Kb   15382 Ki
    2022-04-08T22:42:57-07:00   3.14   0.00   0.00       42        3      20  32079 Kb   5849 Kb    211 Kb    424 Kb   15404 Ki
    <...>
    2022-04-08T22:43:29-07:00  37.50   0.00   0.00       53        3      20  32147 Kb   6469 Kb    212 Kb    424 Kb   49162 Ki
    2022-04-08T22:43:30-07:00  37.50   0.00   0.00       53        3      20  32677 Kb   6643 Kb    212 Kb    424 Kb   50217 Ki
    Code                    ||        QPS       Time
    rand:uniform().          8   54372 Ki     144 ns
```

## Continuous (default) mode
Benchmarking is done by counting number of *runner* iterations done over
a specified period of time (**sample_duration**). See `erlperf` reference for
more details.

Two examples below demonstrate the effect caused by changing *sample_duration*.
First run takes 20 samples (`-s 20`) with 100 ms duration. Second invocation
takes the same 20 sample, but with 200 ms duration (`-d 200`). Note that throughput 
doubled due to sample duration increase, but average time of a single iteration stays
unchanged.

```bash
    $ ./erlperf 'rand:uniform().' -d 100 -s 20
    Code                    ||        QPS       Time
    rand:uniform().          1    1480 Ki      67 ns
    $ ./erlperf 'rand:uniform().' -d 200 -s 20
    Code                    ||        QPS       Time
    rand:uniform().          1    2771 Ki      72 ns
```

## Timed (low overhead) mode
Since 2.0, `erlperf` includes timed mode. It cannot be used for continuous benchmarking. In this mode
runner code is executed specified amount of times in a tight loop:

```bash
    ./erlperf 'rand:uniform().' 'rand:uniform(1000).' -l 10M
    Code                        ||        QPS       Time     Rel
    rand:uniform().              1   16319 Ki      61 ns    100%
    rand:uniform(1000).          1   15899 Ki      62 ns     97%
```

This mode effectively runs following code: `loop(0) -> ok; loop(Count) -> rand:uniform(), loop(Count - 1).`
Timed mode has slightly less overhead compared to continuous mode.

## Concurrency estimation (squeeze) mode
Sometimes it's necessary to measure code running multiple concurrent
processes, and find out when it saturates the VM. It can be used to
detect bottlenecks, e.g. lock contention, single dispatcher process
bottleneck etc. Example (with maximum concurrency limited to 50):

```erlang
    > erlperf:run({code, is_loaded, [local_udp]}, #{warmup => 1}, #{max => 50}).
    {1284971,7}
```

In this example, 7 concurrent processes were able to squeeze 1284971 calls per second
for `code:is_loaded(local_udp)`.

## Benchmarking existing application
`erlperf` can be used to measure performance of your application running in production, or code that is stored
on disk.

Use `-pa` argument to add an extra code path. Example:
```bash
    $ ./erlperf 'argparse:parse([], #{}).' -pa _build/test/lib/argparse/ebin
    Code                             ||        QPS       Time
    argparse:parse([], #{}).          1     955 Ki    1047 ns
```

If you need to add multiple released applications, supply `ERL_LIBS` environment variable instead:
```bash
    $ ERL_LIBS="_build/test/lib" erlperf 'argparse:parse([], #{}).'
    Code                             ||        QPS       Time
    argparse:parse([], #{}).          1     735 Ki    1361 ns
```

## Usage in production
It is possible to use `erlperf` to benchmark a running application (even in production, assuming
necessary safety precautions). To achieve this, add `erlperf` as a dependency, and use remote shell:

```bash
    # run a mock production node with `erl -sname production`
    # connect a remote shell to the production node
    erl -remsh production
    (production@max-au)3> erlperf:run(timer, sleep, [1]).
    488
```

## Infinite continuous benchmarking
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
    > {ok, Logger} = erlperf_file_log:start_link().
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

## erlperf Terms explained
See `erlperf_job` for the detailed reference and ways to define a *callable*.

* **runner**: code that gets continuously executed
* **init**: code that runs one when the job starts. Use it to start registered process or create ETS tables.
* **done**: code that runs when the job is about to stop. Used for cleanup, e.g. stopping registered processes
* **init_runner**: code that is executed in every runner process (e.g. populate process dictionary)
* **job**: single instance of the running benchmark
* **concurrency**: how many worker processes are running concurrently, executing *runner* code
* **throughput**: total number of calls per sampling interval (by all workers of the job)

## Benchmarking under lock contention
ERTS cannot guarantee precise timing when there is severe lock contention happening,
and scheduler utilisation is 100%. This often happens with ETS:
```bash
    $ ./erlperf -c 50 'ets:insert(ac_tab, {1, 2}).'
```
Running 50 concurrent processes trying to overwrite the very same key of an ETS
table leads to lock contention on a shared resource (ETS table/bucket lock). erlperf
may detect this issue and switch to a busy wait loop for precise timing. This may
result in lowered throughput and other metrics skew. erlperf does not attempt to
pinpoint the source of contention, it is up to user to figure that out. It's recommended
to use lock-counting emulator, or Linux `perf` utility to troubleshoot VM-level issues.

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
Use timed mode for such occasions.

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

## Experimental: benchmarking in a cluster

It's possible to run a job on a separate node in the cluster. See
`erlperf_cluster_monitor` for additional details.

```erlang
    % watch the entire cluster (printed to console)
    (node1@host)> {ok, _} = erlperf_history:start_link().
    {ok,<0.213.0>}
    (node1@host)> {ok, ClusterLogger} = erlperf_cluster_monitor:start_link(group_leader(), 1000, [sched_util, jobs]).
    {ok, <0.216.0>}
    
    % also log cluster-wide reports to file (jobs & sched_util)
    (node1@host)> {ok, FileLogger} = erlperf_cluster_monitor:start_link("/tmp/cluster", 1000, [time, sched_util, jobs]).
    {ok, <0.223.0>}

    % run the benchmarking process in a different node of your cluster
    (node1@host)> rpc:call('node2@host', erlperf, run, [#{runner => {rand, uniform, []}}]).
```

Cluster-wide monitoring reflects changes accordingly.


## Implementation details
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

Timed (low-overhead) mode tightens it even further, turning runner into this function:
```erlang
runner(0) ->
    ok;
runner(Count) ->
    rand:uniform(),
    runner(Count - 1).
```