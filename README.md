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
    $ ./erlperf 'timer:sleep(1).'
    Code                    ||        QPS     Rel
    timer:sleep(1).          1        500    100%
```

Run erlperf with two concurrent samples of code


```bash
    $ ./erlperf 'rand:uniform().' 'crypto:strong_rand_bytes(2).' --samples 10 --warmup 1
    Code                         Concurrency   Throughput   Relative
    rand:uniform().                        1      4303 Ki       100%
    crypto:strong_rand_bytes(2).           1      1485 Ki        35%
```

Or just measure how concurrent your code is (example below shows saturation with only 1 process):

```bash
    $ ./erlperf 'code:is_loaded(local_udp).' --init 'code:ensure_loaded(local_udp).' --squeeze
    Code                           ||        QPS
    code:is_loaded(local_udp).      1     614 Ki
```
    
If you need some initialisation done before running the test, and clean up after:

```bash
    $ ./erlperf 'pg:join(scope, self()), pg:leave(scope, self()).' --init 'pg:start_link(scope).' --done 'gen_server:stop(scope).'
    Code                                                     ||        QPS     Rel
    pg:join(scope, self()), pg:leave(scope, self()).          1     287 Ki    100%
```

Run two versions of code against each other, with some init prior:

```bash
    $ ./erlperf 'runner(X) -> timer:sleep(X).' --init '1.' 'runner(Y) -> timer:sleep(Y).' --init '2.'
    Code                                                     ||        QPS     Rel
    pg:join(scope, self()), pg:leave(scope, self()).          1     287 Ki    100%
```
    
Determine how well pg2 (removed in OTP 24) is able to have concurrent group modifications when there are no nodes in the cluster:

```bash
    $ ./erlperf 'runner(Arg) -> ok = pg2:join(Arg, self()), ok = pg2:leave(Arg, self()).' --init_runner 'G = {foo, rand:uniform(10000)}, pg2:create(G), G.' -q
    Code                                                               ||        QPS
    runner(Arg) -> ok = pg2:join(Arg, self()), ok = pg2:leave(Arg,     13      76501
```
    
Watch the progress of your test running (use -v option):

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

# Continuous benchmarking
Starting erlperf as an Erlang application enables continuous benchmarking. This process is designed to help during
development and testing stages, allowing to quickly notice performance regressions.
 
Usage example (assuming you're running an OTP release, or rebar3 shell for your application):

```bash

        $ rebar3 shell --sname mynode
```
```erlang
    > application:start(erlperf).
    ok.
    
    > {ok, Logger} = ep_file_log:start(group_leader()).
    {ok,<0.235.0>}
    
    > {ok, JobPid} = ep_job:start(#{name => myname, 
        init_runner => "myapp:generate_seed().", 
        runner => "runner(Arg) -> Var = mymodule:call(Arg), mymodule:done(Var).",
        initial_concurrency => 1}).
    {ok,<0.291.0>}
    
    > ep_job:set_concurrency(JobPid, 2).
    ok.
    
    % watch your job performance (local node)

    % modify your application code, do hot code reload
    > c:l(mymodule).
    {module, mymodule}.
    
    % stop logging for local node
    > ep_file_log:stop(Logger).
    ok
    
    % stop the job
    > ep_job:stop(JobPid).
    ok.
    
    % restart the job (code is saved for your convenience, and can be accessed by name)
    % makes it easy to restart the job if it crashed due to bad code loaded
    > ep_job:start(erlperf:load(myname)).
    {ok,<0.1121.0>}
    
    % when finished, just shut everything down with one liner:
    > application:stop(erlperf).
    ok.
```


# Reference Guide

## Terms

* **runner**: process repeatedly executing the same set of calls
* **hooks**: functions run when the new job starts (*init*), new runner
 starts (*init_runner*), or when job is stopped (*done*)
* **job**: single instance of the running benchmark (multiple processes)
* **concurrency**: how many processes are running concurrently, executing *runner* code
* **throughput**: total number of calls per sampling interval (for all concurrent processes)

## Usage
Benchmarking is done either using already compiled code, or a free-form
code source. Latter case involves an extra step to form an Erlang module, 
compile it and load into VM. 

## One-time throughput run
Supported use-cases:
 * single run for MFA: ```erlperf:run({rand, uniform, [1000]}).```
 * call chain: ```erlperf:run([{rand, uniform, [10]}, {erlang, node, []}]).```,
 see [recording call chain](#recording-call-chain)
 * anonymous function: ```erlperf:run(fun() -> rand:uniform(100) end).```
 * anonymous object with an argument: ```erlperf:run(fun(Init) -> io_lib:format("~tp", [Init]) end).```
 * source code: ```erlperf:run("runner() -> rand:uniform(20).").```
 
Source code cannot be mixed with MFA. Call chain may contain only complete
MFA tuples and cannot be mixed with functions.

Startup and teardown 
 * init, done and init_runner hooks are available (there is no done_runner,
 because it is never stopped in a graceful way)
 * init_runner and done may be defined with arity 0 and 1 (in the latter case,
 result of init/0 passed as an argument)
 * runner could be of any arity, erlang:function_exported/3 used to 
 determine if it accepts exact or +1 argument from init_runner
 
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
Benchmarking is done by counting number of erlang:apply() calls done
for a specified period of time (**sample_duration**). 
By default, erlperf performs no **warmup** cycle, then takes 3 consecutive 
**samples**, using **concurrency** of 1 (single runner). It is possible 
to tune this behaviour by specifying run_options:
```erlang
    erlperf:run({erlang, node, []}, #{concurrency => 2, samples => 10, warmup => 1}).
```
For list of options available, refer to benchmark reference.

## Concurrency test
Sometimes it's necessary to measure code running multiple concurrent
processes, and find out when it saturates the node. It can be used to
detect bottlenecks, e.g. lock contention, single dispatcher process
bottleneck etc.. Example (with maximum concurrency limited to 50):

```erlang
    erlperf:run(Code, #{warmup => 1}, #{max => 50}).
```

# Continuous benchmarking
All currently running benchmarking jobs can be accessed via programmatic
interface. It is possible to run a job continuously, to examine performance
gains or losses while doing hot code reload.

## Saving benchmarks for future use
Benchmark code database can be maintained for this purpose. Persisting
code samples may not present repeatable tests, but allow re-running
in the future.

## Benchmarking overhead
Not yet measured. There may be a better way (using call time tracing instead of 
counter injections), to be determined later.

## Experimental: recording call chain
Benchmarking can only work with exported functions (unlike ep_prof module,
that is also able to record arguments of local function calls).

```erlang
    > f(Trace), Trace = erlperf:record(pg2, '_', '_', 1000).
    ...
    
    % for things working with ETS, isolation is recommended
    > erlperf:run(Trace, #{isolation => #{}}).
    ...
    
    % Trace can be saved to file before executing:
    > erlperf:run(#{runner => Trace, name => "pg2"}).
    
    % run the trace with
    > erlperf:run(erlperf:load("pg2")).
```

It's possible to create a Common Test testcase using recorded samples.
Just put the recorded file into xxx_SUITE_data:
```erlang
    QPS = erlperf:run(erlperf:load(?config(data_dir, "pg2"))),
    ?assert(QPS > 500). % catches regression for QPS falling below 500
```

## Experimental: starting jobs in a cluster

It's possible to run a job on a separate node in the cluster.

```erlang
    % watch the entire cluster (printed to console)
    > {ok, ClusterLogger} = ep_cluster_monitor:start().
    {ok, <0.211.0>}
    
    % also log cluster-wide reports (jobs & sched_util)
    > {ok, ClusterLogger} = ep_cluster_monitor:start("/tmp/cluster", [time, sched_util, jobs]).
    {ok, <0.223.0>}

    % start the benchmarking process in a separate beam
    > {ok, Node, Job} = erlperf:start(#{
        runner => {timer, sleep, [2]}, initial_concurrency => 4}, 
        #{}).
    {ok,job_53480@centos,<16735.104.0>}

    % tail the file with "tail -f /tmp/cluster"

    % change concurrency:
    > rpc:call(Node, ep_job, set_concurrency, [Job, 8]).
    ok
    
    % watch the log file tail
```

Cluster-wide monitoring will reflect changes accordingly.

## Changelog

Version 1.1.5:
- support for OTP 25 (peer replacing slave)

Version 1.1.4:
- fixed an issue with pg already started
- moved profiling to spawned process

Version 1.1.3:
- addressed deprecation, updated to argparse 1.1.4

Version 1.1.2:
- updated command line parser to new argparse

Version 1.1.1:
- added support for OTP 24
- added edoc documentation

Version 1.0.0:
- initial release
