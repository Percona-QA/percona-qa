SELECT 0 &(JSON_ARRAYAGG(1) OVER a) FROM (SELECT 0) AS b WINDOW a AS ();

select json_arrayagg(a) over () from (select 1 a) t;  # MDEV-21915

SELECT 0 &(JSON_ARRAYAGG(1)OVER w) FROM (select 1) as dt WINDOW w as ();  # MDEV-21915
