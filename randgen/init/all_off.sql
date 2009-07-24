SET GLOBAL OPTIMIZER_SWITCH = 'materialization=off,semijoin=off,loosescan=off,firstmatch=off';

SET GLOBAL optimizer_use_mrr = 'disable';

SET GLOBAL engine_condition_pushdown = 'off';

SET GLOBAL join_cache_level = 0;
