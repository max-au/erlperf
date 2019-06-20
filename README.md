erlperf
=====

Simple way to say "this code is faster than that one".

# TL; DR

Find out how many times per second a function can be run  (beware of shell escaping your code!):

    $ erlperf 'timer:sleep(1).'
    Code               Concurrency   Throughput
    timer:sleep(1).              1          498

Run erlperf with two concurrently running samples of code

    $ erlperf 'rand:uniform().' 'crypto:strong_rand_bytes(2).' --samples 10 --warmup 1
    Code                         Concurrency   Throughput   Relative
    rand:uniform().                        1      4303 Ki       100%
    crypto:strong_rand_bytes(2).           1      1485 Ki        35%

Or just measure how concurrent your code is:

    $ erlperf 'pg2:create(foo).' --squeeze
    Code                         Concurrency   Throughput
    pg2:create(foo).                      14      9540 Ki

Command-line benchmarking does not save results anywhere. It is designed to provide a quick answer to the question
"is that piece of code faster". 

# Continuous benchmarking
Starting erlperf as an Erlang application enables continuous benchmarking. This process is designed to help during
development and testing stages, allowing to quickly notice performance regressions.
 
Usage example (assuming you're running an OTP release, or rebar3 shell for you application):

    $ rebar3 shell
    > application:start(erlperf).
    ok.
    
    > file_log:start().
    {ok,<0.235.0>}
    
    > {ok, JobPid} = job:start(#{name => myname, init_runner => "myapp:generate_seed().", 
      runner => "runner(Arg) -> Var = mymodule:call(Arg), mymodule:done(Var)."}).
    {ok,<0.291.0>}
    
    % watch your job performance
    % modify your application code, do hot code reload
    > c:l(mymodule).
    {module, mymodule}.
    
    % stop the job
    > job:stop(JobPid).
    
    % restart the job (code is saved for your convenience, and can be accessed by name)
    % makes it easy to restart the job if it crashed due to bad code loaded
    > job:start(job:load(myname)).
    {ok,<0.1121.0>}
    
    % when finished, just shut everything down with one liner:
    > application:stop(erlperf).
    ok.


# Reference Guide

## Terms

* **runner**: process repeatedly executing the same set of calls
* **hooks**: functions run when the new job starts (*init*), new runner
 starts (*init_runner*), or when job is stopped (*done*)
* **job**: single instance of the running benchmark (multiple processes)
* **concurrency**: how many processes are running concurrently, executing *runner* code
* **throughput**: total number of calls per sampling interval (for all concurrent processes)

## Build

    $ rebar3 do compile, escriptize

## Usage
Benchmarking is done either using already compiled code, or a free-form
code source. Latter case involves an extra step to form an Erlang module, 
compile it and load into VM. 

## One-time throughput run
Supported use-cases:
 * single run for MFA: ```erlperf:benchmark(rand, uniform, [1000]).```
 * call chain: ```erlperf:benchmark([{rand, uniform, [10]}, {erlang, node, []}]}.```,
 see [recording call chain](#recording-call-chain)
 * function object: ```erlperf:benchmark(fun() -> rand:uniform(100) end).```
 * function object with an argument: ```erlperf:benchmark(fun(Init) -> io_lib:format("~tp", [Init]) end).```
 * source code: ```erlperf:benchmark("runner() -> rand:uniform(20).").```
 
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
```
   erlperf:benchmark(
       #{
           runner => fun(Arg) -> rand:uniform(Arg),
           init => 
               {myserver, start_link(), []},
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
```
erlperf:benchmark(
    {
        runner => "runner(Max) -> rand:uniform(Max).",
        init => "init() -> myserver:start_link().",
        init_runner => "init_runner() -> "
            init_runner({ok, Pid}) ->
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
```
    erlperf:benchmark(Code, #{concurrency => 2, samples => 10, warmup => 1}).
```
For list of options available, refer to benchmark reference.

## Concurrency test
Sometimes it's necessary to measure code running multiple concurrent
processes, and find out when it saturates the node. It can be used to
detect bottlenecks, e.g. lock contention, single dispatcher process
bottleneck etc.. Example (with maximum concurrency limited to 50):

```
    erlperf:benchmark(Code, #{warmup => 1}, #{max => 50}).
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

## Recording call chain
Call Time Profiler (ctp) should be used to record a call chain. Example:
```
    > Trace = ctp:record({ets, lookup, '_'}).
    ...
    > erlperf:benchmark(Trace).
    ...
```


