# Command Line
Run `erlperf` with no arguments to get command line usage.

## Synopsis

```bash
erlperf [FLAG] runner [INIT] [INIT_RUNNER] [DONE] [runner...]
```

## Flags

| Short | Long              | Description                                                                                                                                                      |
|-------|-------------------|------------------------------------------------------------------------------------------------------------------------------------------------------------------|
| -c    | --concurrency     | Specifies the number of workers per job. Allowed only in continuous mode                                                                                         |
|       | --cv              | Coefficient of variation. Accepted in continuous and concurrency estimation mode. Benchmark keeps running until standard deviation is below the specified number |
| -i    | --isolation       | Requests to run every benchmark in a separate Erlang VM for isolation purposes                                                                                   |
| -s    | --samples         | Number of samples to take. Defaults to 1 for timed mode, 3 for continuous and concurrency estimation                                                             |
| -d    | --sample_duration | Sample duration, in milliseconds, for continuous and concurrency estimation modes                                                                                |
| -l    | --loop            | Sample duration (iterations) for the timed mode. Engages timed mode when specified                                                                               |
|       | --max             | Maximum number of workers allowed in the concurrency estimation mode                                                                                             |
|       | --min             | Starting number of workers in concurrency estimation mode                                                                                                        |
| -pa   |                   | Adds extra code path to the Erlang VM. Useful for benchmarking *.beam files on your filesystem                                                                   |
| -r    | --report          | Requests `basic`, `extended` or `full` report. Defaults to `basic` when less than 10 samples are requested, and `extended` for 10 and more                       |
| -q    | -squeeze          | Engages concurrency estimation mode                                                                                                                              |
| -t    | -threshold        | Sets number of extra workers to try in concurrency estimation mode before concluding the test                                                                    |
| -v    | --verbose         | Turns on verbose logging (VM statistics and performance of continuous jobs)                                                                                      |
| -w    | --warmup          | Warmup                                                                                                                                                           |

## Benchmark code
At least one runner code is required. Specify multiple runner codes to perform
a comparison run.

Initialisation and cleanup definitions are read in the same order as runner codes. Example:
```bash
# first runner receives 1 as input, second - 2
erlperf --init_runner '1.' 'run(1) -> ok.' 'run(2) -> ok.' --init_runner '2.'
# next run fails with function_clause, because first runner receives '2', and secdond - 1
erlperf --init_runner '2.' 'run(1) -> ok.' 'run(2) -> ok.' --init_runner '1.' 
```

|                   | Description                                                               |
|-------------------|---------------------------------------------------------------------------|
| --init            | Job initialisation code, see accepted callable formats below              |
| --init_runner     | Worker initialisation code                                                |
| --done            | Job cleanup code                                                          |
|                   |                                                                           |
| --init_all        | Default init code for all runners that do not have a specific code        |
| --init_runner_all | Default init_runner code                                                  |
| --done_all        | Default done code                                                         |

Accepted callable formats:
* valid Erlang code: `timer:sleep(1).`
* valid Erlang function: `run() -> timer:sleep(1).`
* function with arguments: `run(X) -> timer:sleep(X).', 'run(X, Y) -> timer:sleep(X), Y.`
* tuple with module, function name and arguments: `{timer, sleep, [1]}`
* file name with call chain recording: `record.trace`. **deprecated**, do not use 