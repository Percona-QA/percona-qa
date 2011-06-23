query:
	SELECT returns FROM DUAL ;

returns:
	returns_integer | returns_bool | returns_string ;

returns_integer:
	Dimension( geometry ) |
	SRID( geometry ) |
	X( point ) |
	Y( point ) |
	GLength( linestring ) |
	NumPoints( linestring ) |
	GLength( multilinestring ) |
	IsClosed( multilinestring ) |
	Area( polygon ) |
	NumInteriorRings( polygon ) |
	Area( multipolygon ) |
	NumGeometries( geometry_collection ) ;

returns_bool:
	MBRContains( geometry , geometry ) |
	MBRDisjoint( geometry , geometry ) |
	MBREqual( geometry , geometry ) |
	MBRIntersects( geometry , geometry ) |
	MBROverlaps( geometry , geometry ) |
	MBRTouches( geometry , geometry ) |
	MBRWithin( geometry , geometry ) |
	ST_INTERSECTS( geometry , geometry ) |
	ST_CROSSES( geometry , geometry ) |
	ST_EQUALS( geometry , geometry ) |
	ST_WITHIN( geometry , geometry ) |
	ST_CONTAINS( geometry , geometry ) |
	ST_DISJOINT( geometry , geometry ) |
	ST_TOUCHES( geometry , geometry ) ;

returns_string:
	GeometryType( geometry );

point:
	PointFromText(' point_wkt ') |
	EndPoint( linestring ) |
	PointN( linestring , returns_integer ) |
	StartPoint( linestring ) ;

multipoint:
	MultiPointFromText(' multipoint_wkt ') ;

linestring:
	LinestringFromText(' linestring_wkt ') |
	ExteriorRing( polygon ) |
	InteriorRingN( polygon , returns_integer ) ;

multilinestring:
	MultiLineStringFromText(' multilinestring_wkt ');
	
polygon:
	PolyFromText(' polygon_wkt ') |
	Envelope( geometry ) ;

multipolygon:
	MultiPolygonFromText(' multipolygon_wkt ') ;

geometry:
	ST_UNION( geometry , geometry ) |
	ST_INTERSECTION( geometry , geometry ) |
#	ST_SYMDIFFERENCE( geometry , geometry ) |
#	ST_BUFFER( geometry , returns_integer ) |
	GeometryFromText(' geometry_wkt ') |
	GeometryN( geometry_collection , returns_integer ) |
	point | linestring | polygon |
	multipoint | multilinestring | multipolygon ;

geometry_collection:
	GeometryCollectionFromText(' geometrycollection_wkt ') ;

geometry_wkt:
	point_wkt | linestring_wkt | polygon_wkt |
	multipoint_wkt | multilinestring_wkt | multipolygon_wkt ;

geometrycollection_wkt:
	GEOMETRYCOLLECTION( geometry_wkt_list ) ;

geometry_wkt_list:
	geometry_wkt , geometry_wkt |
	geometry_wkt , geometry_wkt_list ;

point_arg:
	coord coord ;

point_wkt:
	POINT( point_arg );

linestring_wkt:
	LINESTRING( point_list ) ;

polygon_wkt:
	POLYGON( actual_polygon ) |
	POLYGON( point_list ) |
	POLYGON( line_list ) ;

multipoint_wkt:
	MULTIPOINT( point_list ) ;

multilinestring_wkt:
	MULTILINESTRING( line_list ) ;

multipolygon_wkt:
	MULTIPOLYGON( actual_polygon_list ) |
	MULTIPOLYGON( line_list ) ;

actual_polygon_list:
	actual_polygon , actual_polygon |
	actual_polygon_list , actual_polygon ;

actual_polygon:
	0 0 , point_arg , point_arg , 0 0 |
	9 9 , point_arg , point_arg , 9 9 |
	2 2 , coord 2 , point_arg , 2 coord , 2 2 |
	7 7 , coord 7, point_arg, 7 coord , 7 7 ;

point_list:
	actual_polygon |
	point_arg , point_arg , point_arg |
	point_arg , point_list ;

line_list:
	( point_list ) , ( point_list ) |
	( point_list ) , line_list ;

coord:
	_digit ;
