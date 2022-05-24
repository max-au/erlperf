# Changelog

## 2.0.2
- added convenience command line options: init_all, done_all, init_runner_all

## 2.0.1
- minor bugfixes (friendlier error reporting)

## 2.0
- incompatible change: `erlperf` requires runner arity to be defined explicitly.
  Code example: `erlperf:run(#{runner => {timer, sleep, []}, init_runner => "1."})`,
  with `erlperf` making a guess that `init_runner` is defined, therefore its return
  value can be passed as the argument to `timer:sleep/1`. This behaviour was confusing
  and is no longer supported.
- incompatible change: crashed runner causes entire job to stop (error contains the
  reason and stack trace)
- incompatible change: removed fprof/profiling support in favour of JIT + `perf`
- `erlperf` application is no longer required to be started for one-off benchmark runs

## 1.1.5:
- support for OTP 25 (peer replacing slave)

## 1.1.4:
- fixed an issue with pg already started
- moved profiling to spawned process

## 1.1.3:
- addressed deprecation, updated to argparse 1.1.4

## 1.1.2:
- updated command line parser to new argparse

## 1.1.1:
- added support for OTP 24
- added edoc documentation

## 1.0.0:
- initial release
