query:
        transaction;

transaction:
        START TRANSACTION ; query_list ; COMMIT ;

query_list:
        query_item |
        query_item ; query_list ;

query_item:
        select | dml ;

select:
        SELECT DISTINCT /* RESULTSET_ZERO_OR_ONE_ROWS _quid */ `int_key` FROM _table ;

dml:
        UPDATE _table SET `int_key` = _int_unsigned |
        DELETE FROM _table LIMIT 1 ;

