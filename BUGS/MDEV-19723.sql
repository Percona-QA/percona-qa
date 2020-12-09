SELECT ST_GEOMFROMGEOJSON("{\"type\":[]}",1);

SELECT ST_GEOMFROMGEOJSON("{ \"type\": \"Feature\", \"geometry\": [10, 20] }");

SELECT ST_ASTEXT(ST_GEOMFROMGEOJSON("{ \"type\": [ \"Point\" ],\"coordinates\": [10,15] }",1,0));

SELECT ST_GEOMFROMGEOJSON("{\"\":\"\",\"coordinates\":[0]}");

SELECT ST_ASTEXT(ST_GEOMFROMGEOJSON("{ \"type\": \"GEOMETRYcLECTION\",\"coordinates\": [0.0,0.0]}"));

SELECT ST_GEOMFROMGEOJSON("{ \"type\": \"FeatureCollection\", \"coordinates\": [10, 10] }");

SELECT st_astext (st_geomfromgeojson ("{ \"type1234567890\": \"POINT\", \"coORdinates\": [102, 11]}"));

# mysqld options required for replay: --log-bin
SET SQL_MODE='';
SET @@enforce_storage_engine=MyISAM;
CREATE TABLE t1 (a INT) ENGINE=RocksDB SELECT 42 a;
SET GLOBAL wsrep_forced_binlog_format=STATEMENT;
REPLACE DELAYED t1 VALUES (5);
SELECT ST_ASTEXT (ST_GEOMFROMGEOJSON ("{ \"type1234567890\": \"POINT\", \"coordinates\": [102, 11]}"));

# mysqld options required for replay: --log-bin
CREATE TABLE t1 (ROWID INT, f1 INT, f2 INT, KEY i1 (f1, f2), KEY i2 (f2)) ENGINE=MyISAM;
SET GLOBAL wsrep_forced_binlog_format='STATEMENT';
INSERT DELAYED INTO t1 VALUES ('24','1','1');
SELECT ST_GEOMFROMGEOJSON ("{ \"type\": \"Feature\", \"GEOMETRY\": [10, 20] }");
