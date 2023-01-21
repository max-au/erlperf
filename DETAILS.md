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

Timed (low-overhead) mode tightens it even further, turning runner into this function:
```erlang
runner(0) ->
    ok;
runner(Count) ->
    rand:uniform(),
    runner(Count - 1).
```