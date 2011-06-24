query:
	SELECT returns_string ;

returns_list:
	returns , returns , returns |
	returns , returns , returns_list ;

returns:
	returns_integer | returns_bool | returns_string ;

returns_integer:
	/*executor1 Dimension( */ /*executor2 ST_NDims( */ geometry ) |
#	SRID( geometry ) |
	/*executor1 X( */ /*executor2 ST_X( */ point ) |
	/*executor1 X( */ /*executor2 Y( */ point ) |
	/*executor1 GLength( */ /*executor2 ST_Length( */ linestring ) |
	/*executor1 NumPoints( */ /*executor2 ST_NumPoints( */ linestring ) |
	/*executor1 GLength( */ /*executor2 ST_Length( */ multilinestring ) |
	/*executor1 IsClosed( */ /*executor2 ST_IsClosed( */ multilinestring ) |
	/*executor1 Area( */ /*executor2 ST_Area( */ polygon ) |
	/*executor1 NumInteriorRings( */ /*executor2 ST_NumInteriorRings( */ polygon ) |
	/*executor1 Area( */ /*executor2 ST_Area( */ multipolygon ) |
	/*executor1 NumGeometries( */ /*executor2 ST_NumGeometries( */ geometry_collection ) ;

returns_bool:
#	MBRContains( geometry , geometry ) |
#	MBRDisjoint( geometry , geometry ) |
#	MBREqual( geometry , geometry ) |
#	MBRIntersects( geometry , geometry ) |
#	MBROverlaps( geometry , geometry ) |
#	MBRTouches( geometry , geometry ) |
#	MBRWithin( geometry , geometry ) |
	ST_INTERSECTS( geometry , geometry ) |
	ST_CROSSES( geometry , geometry ) |
	ST_EQUALS( geometry , geometry ) |
	ST_WITHIN( 1d , 2d) | ST_WITHIN( 2d , 2d ) |
	ST_CONTAINS( 1d , 2d ) | ST_CONTAINS( 2d , 2d ) ;
	ST_DISJOINT( geometry , geometry ) |
	ST_TOUCHES( geometry , geometry ) ;

2d:
	polygon | multipolygon ;

1d:
	linestring | multilinestring ;

returns_string:
	/*executor1 AsText( */ /*executor2 ST_AsEWKT( */ geometry ) |
	GeometryType( geometry );

point:
	/*executor1 PointFromText(' */ /*executor2 ST_PointFromText(' */ point_wkt ') |
	/*executor1 EndPoint( */ /*executor2 ST_EndPoint( */ linestring ) |
	/*executor1 PointN( */ /*executor2 ST_PointN( */ linestring , returns_integer ) |
	/*executor1 StartPoint( */ /*executor2 ST_StartPoint( */ linestring ) ;

multipoint:
	/*executor1 MultiPointFromText(' */ /*executor2 ST_MPointFromText(' */ multipoint_wkt ') ;

linestring:
	/*executor1 LinestringFromText(' */ /*executor2 ST_LineFromText(' */ linestring_wkt ') |
	/*executor1 ExteriorRing( */ /*executor2 ST_ExteriorRing( */ polygon ) |
	/*executor1 InteriorRingN( */ /*executor2 ST_InteriorRingN( */ polygon , returns_integer ) ;

multilinestring:
	/*executor1 MultiLineStringFromText(' */ /*executor2 ST_MLineFromText(' */ multilinestring_wkt ') ;
	
polygon:
	/*executor1 PolygonFromText(' */ /*executor2 ST_PolygonFromText(' */ polygon_wkt ') |
	Envelope( 2d ) ;

multipolygon:
	/*executor1 MultiPolygonFromText(' */ /*executor2 ST_MPolyFromText(' */ multipolygon_wkt ') ;

geometry:
	ST_UNION( geometry , geometry ) |
	ST_INTERSECTION( geometry , geometry ) |
#	ST_SYMDIFFERENCE( geometry , geometry ) |
#	ST_BUFFER( geometry , returns_integer ) |
	/*executor1 GeometryFromText(' */ /*executor2 ST_GeometryFromText(' */ geometry_wkt ') |
	/*executor1 GeometryN( */ /*executor2 ST_GeometryN( */ geometry_collection , returns_integer ) |
	point | linestring | polygon |
	multipoint |
	multilinestring |
	multipolygon ;

geometry_collection:
	/*executor1 GeometryCollectionFromText(' */ /*executor2 ST_GeomCollFromText(' */ geometrycollection_wkt ') ;

geometry_wkt:
	point_wkt | linestring_wkt | polygon_wkt |
	multipoint_wkt |
	multilinestring_wkt |
	multipolygon_wkt ;

geometry_wkt_list:
	geometry_wkt , geometry_wkt |
	geometry_wkt , geometry_wkt_list ;

point_arg:
	coord coord ;

geometrycollection_wkt:
	GEOMETRYCOLLECTION( geometry_wkt_list ) ;

point_wkt:
	POINT( point_arg );

linestring_wkt:
	LINESTRING( point_list ) ;

polygon_wkt:
	POLYGON( actual_polygon ) |
	POLYGON( point_list ) ;
#|
#	POLYGON( line_list ) ;

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
#|
#	( 2 2 , 2 8 , 8 8 , 8 2 , 2 2 ) , ( 4 4 , 4 6 , 6 6 , 6 4 , 4 4 ) ;

point_list:
	actual_polygon |
	point_arg , point_arg , point_arg |
	point_arg , point_list ;

line_list:
	( point_list ) , ( point_list ) |
	( point_list ) , line_list ;

coord:
	_digit ;
