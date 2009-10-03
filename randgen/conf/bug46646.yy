query:
        transaction |
        UPDATE _table AS X SET _field_no_pk = _digit WHERE X . `pk` = ( SELECT `pk` FROM _table WHERE `pk` = _digit ) LIMIT 5;

transaction:
        START TRANSACTION |
        SELECT SLEEP( 1 );
