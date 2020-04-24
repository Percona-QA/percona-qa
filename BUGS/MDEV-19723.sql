SELECT ST_GEOMFROMGEOJSON("{\"type\":[]}",1);

SELECT ST_GEOMFROMGEOJSON("{ \"type\": \"Feature\", \"geometry\": [10, 20] }");

SELECT ST_ASTEXT(ST_GEOMFROMGEOJSON("{ \"type\": [ \"Point\" ],\"coordinates\": [10,15] }",1,0));
