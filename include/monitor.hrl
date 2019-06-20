
%% Job sample
-type job_sample() :: {
    ID :: pid(),
    Cycles :: non_neg_integer()
}.


%% Monitoring sampling structure
-record(monitor_sample, {
    time :: integer(),
    sched_util :: float(),
    dcpu :: float(),
    dio :: float(),
    processes :: integer(),
    ports :: integer(),
    ets :: integer(),
    memory_total :: non_neg_integer(),
    memory_processes :: non_neg_integer(),
    memory_binary :: non_neg_integer(),
    memory_ets :: non_neg_integer(),
    jobs :: [job_sample()]
}).

-type monitor_sample() :: #monitor_sample{}.

% monitoring event bus
-define(SYSTEM_EVENT, ep_system_event).

% job event bus
-define(JOB_EVENT, ep_job_event).

% history server pg2 group
-define(HISTORY_PROCESS_GROUP, erlperf_history).
