query:
  SELECT select_clause FROM t_geom where_clause ;

select_clause:
  g|id|ST_AsText(g)|ST_AsWKT(g) ;

where_clause:
  WHERE predicate ;

predicate:
  ST_Intersects(g, ST_GeomFromText($wkt)) |
  ST_Contains(ST_GeomFromText($wkt), g) |
  ST_Distance(g, ST_PointFromText($point)) < 5 |
  id = $id ;

$wkt:
  'POINT(1 1)' | 'POINT(10 10)' | 'LINESTRING(0 0,10 10)' ;

$point:
  'POINT(0 0)' | 'POINT(5 5)' ;

$id:
  1|2|3|4 ;




