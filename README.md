# erlperf

[![Build Status](https://github.com/max-au/erlperf/actions/workflows/erlang.yml/badge.svg?branch=master)](https://github.com/max-au/erlperf/actions) [![Hex.pm](https://img.shields.io/hexpm/v/erlperf.svg)](https://hex.pm/packages/erlperf) [![Hex Docs](https://img.shields.io/badge/hex-docs-blue.svg)](https://hexdocs.pm/erlperf)

Erlang Performance & Benchmarking Suite.
Simple way to say "this code is faster than that one". See [CLI reference](CLI.md)
and detailed API reference for `erlperf` and `erlperf_job` modules.

Build (tested with OTP 23-27):

```bash
    $ rebar3 as prod escriptize
```

## Quick start: command line
Beware of the shell escaping your code in an unpredictable way!

1. Run a single process iterating `rand:uniform()` in a tight loop for 3 seconds,
printing **average iterations per second** (~17 millions) and an average time
to run a single iteration (57 ns).

```bash
    $ ./erlperf 'rand:uniform().'
    Code                    ||        QPS       Time
    rand:uniform().          1   17266 Ki      57 ns
```

2. Run four processes doing this same concurrently.

```bash
    $ ./erlperf 'rand:uniform().' -c 4
    Code                    ||        QPS       Time
    rand:uniform().          4   53893 Ki      74 ns
```

3. Benchmark `rand:uniform()` vs `crypto:strong_rand_bytes/1` for 10 seconds, adding
an extra second to warm up the algorithms.

```bash
    $ ./erlperf 'rand:uniform().' 'crypto:strong_rand_bytes(2).' --samples 10 --warmup 1
    Code                             ||   Samples       Avg   StdDev    Median      P99  Iteration    Rel
    rand:uniform().                   1        10  16611 Ki    0.20%  16614 Ki 16664 Ki      60 ns   100%
    crypto:strong_rand_bytes(2).      1        10   1804 Ki    0.79%   1797 Ki  1829 Ki     554 ns    11%
```

4. Run a function passing the state into the next iteration. This code demonstrates performance difference
between `rand:uniform_s/1` with state passed explicitly, and `rand:uniform/1` reading state from the process
dictionary.

```bash
    $ ./erlperf 'r(_, S) -> {_, N} = rand:uniform_s(S), N.' --init_runner 'rand:seed(exsss).' \
                'r() -> rand:uniform().'
    Code                                              ||        QPS       Time   Rel
    r(_, S) -> {_, N} = rand:uniform_s(S), N.          1   26180 Ki      38 ns  100%
    r() -> rand:uniform().                             1   16958 Ki      58 ns   65%
```

5. Estimate `./erlperf 'application_controller:is_running(kernel).` concurrency characteristics. This function
is implemented as `gen_server:call`, and all calculations are done in a single process. It is still
possible to squeeze a bit more from a single process by putting work into the queue from multiple runners.

```bash
    $ ./erlperf 'application_controller:is_running(kernel).' --squeeze
    Code                                               ||        QPS       Time
    application_controller:is_running(kernel).          3    1189 Ki    2524 ns



    $ ./erlperf 'persistent_term:put(atom, "string").' -q
    Code                                         ||        QPS       Time
    persistent_term:put(atom, "string").          1    8882 Ki     112 ns
```

6. Start a server (`pg` scope in this example), use it in benchmark, and shut down after.

```bash
    $ ./erlperf 'pg:join(scope, group, self()), pg:leave(scope, group, self()).' \
                --init 'pg:start_link(scope).' --done 'gen_server:stop(scope).'
    Code                                                                   ||        QPS       Time
    pg:join(scope, group, self()), pg:leave(scope, group, self()).          1     336 Ki    2976 ns
```

7. Run the same code with different arguments, returned from `init_runner` function. Note the trick
of adding extra spaces in the source code to know which code is where.

```bash
    $ ./erlperf 'runner(X) -> timer:sleep(X).' --init_runner '1.' \
                '  runner(X) -> timer:sleep(X).' --init_runner '2.'
    Code                                   ||        QPS       Time   Rel
    runner(X) -> timer:sleep(X).            1        500    2001 us  100%
      runner(X) -> timer:sleep(X).          1        333    3001 us   67%
```

8. Determine how many times a process can join/leave pg2 group on a single node (requires OTP 23
or older, as pg2 is removed in later versions).

```bash
    $ ./erlperf 'ok = pg2:join(g, self()), ok = pg2:leave(g, self()).' --init 'pg2:create(g).'
    Code                                                         ||        QPS       Time
    ok = pg2:join(g, self()), ok = pg2:leave(g, self()).          1      64021   15619 ns
```

9. Compare `pg` with `pg2` running in a 3-node cluster. Note the `-i` argument spawning an isolated
extra Erlang VM for each benchmark.

```bash
    ./erlperf 'ok = pg2:join(g, self()), ok = pg2:leave(g, self()).' --init 'pg2:create(g).' \
              'ok = pg:join(g, self()), ok = pg:leave(g, self()).' --init 'pg:start(pg).' -i
    Code                                                         ||        QPS       Time     Rel
    ok = pg:join(g, self()), ok = pg:leave(g, self()).            1     241 Ki    4147 ns    100%
    ok = pg2:join(g, self()), ok = pg2:leave(g, self()).          1       1415     707 us      0%
```

10. Watch the progress of your test running (`-v` option) with extra information: scheduler utilisation, dirty CPU & IO
schedulers, number of running processes, ports, ETS tables, and memory consumption. Last column is the job throughput.
When there are multiple jobs, multiple columns are printed. Test will continue until adding 8 more workers (`-t 8`)
does not increase total throughput.

```bash
    $ ./erlperf 'rand:uniform().' -q -v -t 8

    YYYY-MM-DDTHH:MM:SS-oo:oo  Sched   DCPU    DIO    Procs    Ports     ETS Mem Total  Mem Proc   Mem Bin   Mem ETS     <0.84.0>
    2023-01-22T11:02:51-08:00   6.12   0.00   0.20       46        2      21  24737 Kb   4703 Kb    191 Kb    471 Kb     14798 Ki
    2023-01-22T11:02:52-08:00   6.31   0.00   0.00       46        2      21  25105 Kb   5565 Kb    218 Kb    472 Kb     16720 Ki
    2023-01-22T11:02:53-08:00   6.26   0.00   0.00       46        2      21  25501 Kb   5427 Kb    218 Kb    472 Kb     16715 Ki
    <...>
    2023-01-22T11:03:37-08:00 100.00   0.00   0.00       61        2      21  25874 Kb   5696 Kb    221 Kb    472 Kb     55235 Ki
    2023-01-22T11:03:38-08:00 100.00   0.00   0.00       61        2      21  25955 Kb   5565 Kb    218 Kb    472 Kb     55139 Ki
    Code                    ||        QPS       Time
    rand:uniform().          8   61547 Ki     130 ns

```

## Benchmark
Running benchmark is called a **job**, see `erlperf_job` for detailed description.
Every job has a controller process, responsible for starting and stopping worker
processes, or **workers**. Worker processes execute **runner** function in a tight
loop, incrementing **iteration** counter.

Benchmark runs either for a specified amount of time (**sample duration** in
continuous mode), or until requested number of iterations is made (timed mode).
Resulting **sample** is total number of *iterations* for all workers, or elapsed time
it took in timed mode.

The process repeats until the specified amount of *samples* is collected, producing
a **report** (see details below).

For comparison convenience, basic reports contain **QPS** - historical metric
from the original implementation (designed for network service throughput assessment).
It is approximate amount of *runner iterations per sample_duration achieved by all workers
of the job*. Given that default duration is 1 second, *QPS* is a good proxy for
the total job throughput.

Single worker performance can be estimated using **time** metric. It can also be
considered as function latency - how long it takes on average to execute a
single *iteration* of a *runner*.

### Benchmark definition
A benchmark may define following functions:
* **runner**: code that is executed in the tight loop
* **init** (optional): executed once when the job starts
* **done** (optional): executed once when the job is about to stop
* **init_runner** (optional): executed on every worker process startup

See `erlperf_job` for the detailed reference and ways to define a function (**callable**).

Note that different ways to call a function have different performance characteristics:

```bash
    $ ./erlperf '{rand, uniform, []}' 'rand:uniform().' -l 10M
    Code                      ||        QPS       Time   Rel
    rand:uniform().            1   18519 Ki      54 ns  100%
    {rand,uniform,[]}          1   16667 Ki      60 ns   90%
```

This difference may get more pronounced depending on ERTS version and *runner* code:

```erlang
    (erlperf@max-au)7> erlperf:benchmark([
            #{runner => "runner(X) -> is_float(X).", init_runner=>"2."},
            #{runner => {erlang, is_float, [2]}},
            #{runner => fun (X) -> is_float(X) end, init_runner => "2."}],
        #{}, undefined).
    [105824351,66424280,5057372]
```

It is caused by the ERTS: running compiled code (first variant) with OTP 25 is
two times faster than applying a function, and 20 times faster than repeatedly
calling anonymous `fun`. Use the same invocation method to get a relevant result.

Absolute benchmarking overhead may be significant for very fast functions taking just a few nanoseconds.
Use timed mode for such occasions.

### Run options
See `erlperf` module documentation and [command line reference](CLI.md) for all available options.

## Benchmarking modes

### Continuous mode
Benchmarking is done by counting number of *runner* iterations done over
a specified period of time (**sample_duration**).

Two examples below demonstrate the effect caused by changing *sample_duration*.
First run takes 20 samples (`-s 20`) with 100 ms duration. Second invocation
takes the same 20 sample, but with 200 ms duration (`-d 200`). Note that all metrics,
except a single *iteration* time, doubled.

```bash
    $ ./erlperf 'rand:uniform().' -d 100 -s 20
    Code                ||   Samples       Avg   StdDev    Median      P99  Iteration
    rand:uniform().      1        20   1647 Ki    0.39%   1648 Ki  1660 Ki      60 ns
    $ ./erlperf 'rand:uniform().' -d 200 -s 20
    Code                ||   Samples       Avg   StdDev    Median      P99  Iteration
    rand:uniform().      1        20   3354 Ki    0.16%   3354 Ki  3368 Ki      59 ns
```

### Timed mode
In this mode *runner* code is executed for *sample_duration* iterations for every *sample*.
Report contains average/median/p99 *time* it takes to produce a single sample. In the
example below, it takes an average of 554 ms to make 10 million calls to `rand:uniform()`.

```bash
    $ ./erlperf 'rand:uniform().' 'rand:uniform(1000).' -l 10M -s 20
    Code                    ||   Samples       Avg   StdDev    Median      P99  Iteration    Rel
    rand:uniform(1000).      1        20    554 ms    0.37%    554 ms   563 ms      55 ns   100%
    rand:uniform().          1        20    560 ms    0.60%    560 ms   564 ms      55 ns    99%
```

Effectively, this example runs following code: `loop(0) -> ok; loop(Count) -> rand:uniform(), loop(Count - 1).`
Timed mode has slightly less overhead compared to continuous mode.

Timed mode does not support `--concurrency` setting, using only
one process. However, it does support comparison run with multiple concurrent jobs.

### Concurrency estimation mode
In this mode `erlperf` performs multiple continuous benchmarks with
increasing concurrency. The test concludes when increasing worker
count does not result in increase of the total throughput. Report
contains statistics of the most successful run.

This mode can also be used to detect bottlenecks, e.g. lock contention, single
`gen_server` processes, or VM-wide shared resources (`persistent_term`s).
Example (with maximum concurrency limited to 50):

```bash
    $ ./erlperf '{code, is_loaded, [local_udp]}' -w 1 --max 50 -q
    Code                                 ||        QPS       Time
    {code,is_loaded,[local_udp]}          6    1665 Ki    3604 ns
```

Same in the Erlang shell:

```erlang
    > erlperf:run({code, is_loaded, [local_udp]}, #{warmup => 1}, #{max => 50}).
   {1676758,6}
```

In this example, 6 concurrent processes were able to squeeze 1676758 calls per second
for `code:is_loaded(local_udp)`. In current OTP version `code:is_loaded` is implemented
as a `gen_server:call` to a single process (`code_server`), that limits potential
performance.

See `erlperf_job` for the detailed description of different benchmarking modes.

## Reports
Historically `erlperf` had only the basic reporting available for command line
usage. Since 2.2 it is possible to request additional information.

### Basic report
This is the default report form when less than 10 samples were collected.
Use `-r basic` to force basic reports with 10 and more samples.

Basic report contains following columns:
 * **Code**: Erlang code supplied to the benchmark
 * **||**: how many concurrent processes were running. In the timed mode, it is always 1. In the concurrency
   estimation mode, the number that achieved the highest total throughput (QPS)
 * **QPS**: average number of runner code *iterations* (throughput). Measure per single *sample_duration*
      in the continuous mode. In the timed mode, calculated with the assumption that *sample_duration* is 1 second
 * **Time**: single runner iteration time
 * **Rel**: relative performance of this code, compared to others. Printed only when more than
   one runner is specified.

### Extended report
When 10 or more samples were collected, this mode is the default. Use `-r extended`
to force printing this report for smaller sample sets.

Note that average, deviation, median and 99th percentile are calculated for the *sample_duration*.
If you requested 20 samples of 100 ms in the continuous mode, these fields will contain *iteration*
count per 100 ms. If you requested 10 million iterations (`-l 10M`), extended report for timed mode
displays average time it takes to do 10M iterations. Single iteration time is printed as *Iteration*.

Code, concurrency, and relative performance fields have the same meaning as in basic report. In addition,
following columns are printed:
 * **Samples**: how many samples were collected (useful when requesting continuous test with standard deviation requirement)
 * **Avg**: same as QPS for continuous mode, but in the timed mode, average sample time
 * **StdDev**: standard deviation from average
 * **Median**: median value, in the continuous mode, median estimated throughput, in the timed mode - time to
 complete the requested iterations
 * **Iteration**: single runner iteration time
 * **P99**: 99th percentile

### Full report
This mode must be explicitly specified with `-r full`.

Contains everything that extended report has. Includes extra information about the system
used for benchmarking - OS type, CPU and Erlang VM characteristics.

## Benchmarking compiled code
`erlperf` can be used to measure performance of your application running in production, or code that is stored
on disk.

Use `-pa` argument to add an extra code path. Example:
```bash
    $ ./erlperf 'args:parse([], #{}).' -pa _build/test/lib/argparse/ebin
    Code                             ||        QPS       Time
    args:parse([], #{}).              1     955 Ki    1047 ns
```

If you need to add multiple released applications, supply `ERL_LIBS` environment variable instead:
```bash
    $ ERL_LIBS="_build/test/lib" erlperf 'args:parse([], #{}).'
    Code                             ||        QPS       Time
    args:parse([], #{}).              1     735 Ki    1361 ns
```

### Usage in production
It is possible to use `erlperf` to benchmark an application running in production.
Add `erlperf` as a dependency, and use remote shell:

```bash
    # connect a remote shell to the production node
    erl -remsh production@max-au
    (production@max-au)3> erlperf:run(timer, sleep, [1]).
    488
```

### Permanent continuous benchmarking
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

## Timer precision
ERTS cannot guarantee precise timing when there is severe lock contention happening,
and scheduler utilisation is 100%. This often happens with ETS:

```bash
    $ ./erlperf -c 50 'ets:insert(ac_tab, {1, 2}).' -d 100 -s 50
    Timer accuracy problem detected, results may be inaccurate

    Code                            ||   Samples       Avg   StdDev    Median      P99  Iteration
    ets:insert(ac_tab, {1, 2}).     50        50      6079   82.27%      5497    40313     823 us
```

Running 50 concurrent processes trying to overwrite the very same key of an ETS
table leads to lock contention on a shared resource (ETS table/bucket lock). `erlperf`
may detect this issue and switch to a busy wait loop for precise timing. This may
result in lowered throughput and other metrics skew. `erlperf` does not attempt to
pinpoint the source of contention, it is up to user to figure that out. It's recommended
to use lock-counting emulator, or Linux `perf` utility to troubleshoot VM-level issues.


## Experimental features
These features are not fully supported. APIs may change in the future `erlperf`
releases.

### Benchmarking in a cluster
It's possible to run a job on a separate node in the cluster. See
`erlperf_cluster_monitor` for additional details.

```erlang
    % watch the entire cluster (printed to console)
    (node1@host)> {ok, _} = erlperf_history:start_link().
    {ok,<0.213.0>}
    (node1@host)> {ok, ClusterLogger} = erlperf_cluster_monitor:start_link(group_leader(), 1000, [node, sched_util, jobs]).
    {ok, <0.216.0>}

    % also log cluster-wide reports to file (jobs & sched_util)
    (node1@host)> {ok, FileLogger} = erlperf_cluster_monitor:start_link("/tmp/cluster", 1000, [time, node, sched_util, jobs]).
    {ok, <0.223.0>}

    % run the benchmarking process in a different node of your cluster
    (node1@host)> rpc:call('node2@host', erlperf, run, [#{runner => {rand, uniform, []}}]).
```
