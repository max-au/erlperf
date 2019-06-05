erlperf
=====

Continuous micro-benchmarking application. Simple web interface is 
provided as a separate Erlang application.

# Terms

* **runner**: process repeatedly executing the same set of calls
* **hooks**: functions run when the new job starts (init), new runner
 starts (init_runner), or when job is stopped (done)
* **job**: single instance of the running benchmark (multiple runners)
* **throughput**: total number of calls per sampling interval done by
 all runners of a job
* **benchmark**: uniquely identifiable set of code & properties, allowing
 to spawn jobs
* **result**: output of a single job for a selected benchmark  


## Benchmark
Benchmark has following properties:
 * unique identifier
 * name 
 * description
 * jobs currently running this benchmark
 * previous results
 * code for runner (id)
 * hooks code (id, id)
 
## Result
Fields recorded:
 * unique identifier
 * benchmark identifier
 * start/end time
 * system-related information
 * code identifiers (runner, hooks)
 * throughput reached 


# Build

    $ rebar3 compile


# Usage
Benchmarking is done either using already compiled code, or a free-form
code source. Latter case involves an extra step to form an Erlang module
using code provided, compile it and load into VM. 

## One-time throughput run
Supported use-cases:
 * single run for MFA: ```benchmark:run(rand, uniform, [1000]).```
 * call chain: ```benchmark:run([{rand, uniform, [10]}, {erlang, node, []}]}.```,
 see [recording call chain](#recording-call-chain)
 * function object: ```benchmark:run(fun() -> rand:uniform(100) end).```
 * function object with an argument: ```benchmark:run(fun(Init) -> io_lib:format("~tp", [Init]) end).```
 * source code: ```benchmark:run("runner() -> rand:uniform(20).").```
 
Source code cannot be mixed with MFA. Call chain may contain only complete
MFA tuples and cannot be mixed with functions.

Startup and teardown 
 * init, done and init_runner hooks are available (there is no done_runner,
 because it is never stopped in a graceful way)
 * init_runner and done may be defined with arity 0 and 1, result of
 init/0 is passed
 * runner could be of any arity, erlang:function_exported/3 used to 
 determine if it accepts exact or +1 argument from init_runner
 
Example with mixed MFA:
```
   benchmark:run(
       {
           fun(Arg) -> rand:uniform(Arg), % runner
           #{
               init => 
                   {myserver, start_link(), []},
               init_runner => 
                   fun ({ok, Pid}) -> 
                       {total_heap_size, THS} = erlang:process_info(Pid, total_heap_size),
                       THS
                   end,
               done => fun ({ok, Pid}) -> gen_server:stop(Pid) end 
           }
       }
   ).
``` 
 
Same example with source code:
```
benchmark:run(
    {
        "runner(Max) -> rand:uniform(Max).",
        #{
            init => "init() -> myserver:start_link().",
            init_runner => "init_runner() -> "
                init_runner({ok, Pid}) ->
                {total_heap_size, THS} = erlang:process_info(Pid, total_heap_size),
                THS.",
            done => "done({ok, Pid}) -> gen_server:stop(Pid)."
        }
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
    benchmark:run(Code, #{concurrency => 2, samples => 10, warmup => 1}).
```
For list of options available, refer to benchmark reference.

## Concurrency test
Sometimes it's necessary to measure code running multiple concurrent
processes, and find out when it saturates the node. It can be used to
detect bottlenecks, e.g. lock contention, single dispatcher process
bottleneck etc.

# Continuous benchmarking
All currently running benchmarking jobs can be accessed via programmatic
interface. It is possible to run a job continuously, to examine performance
gains or losses while doing hot code reload.

## Saving benchmarks for future use
Benchmark code database can be maintained for this purpose. Persisting
code samples may not present repeatable tests, but allow re-running
in the future.

# Reference

## Benchmarking overhead 

## Recording call chain



