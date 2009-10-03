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
        SELECT /* RESULTSET_SAME_DATA_IN_EVERY_ROW _quid */ `int_key` FROM _table ;

dml:
        UPDATE _table SET `int_key` = _int_unsigned |
        DELETE FROM _table LIMIT 1 ;

