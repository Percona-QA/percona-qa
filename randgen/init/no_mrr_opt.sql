SET GLOBAL OPTIMIZER_SWITCH = 'materialization=on,semijoin=on,loosescan=off,firstmatch=off';

SET GLOBAL optimizer_use_mrr = 'disable';

SET GLOBAL engine_condition_pushdown = 'off';
