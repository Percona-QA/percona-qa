-- Minimal schema for GIS grammar
CREATE DATABASE IF NOT EXISTS test;
USE test;

CREATE TABLE t_geom (
  id    INT PRIMARY KEY,
  g     GEOMETRY NOT NULL,
  SPATIAL INDEX g_spatial (g)
) ENGINE=InnoDB;

-- Optional: add a few rows manually for quick testing
INSERT INTO t_geom (id, g) VALUES
  (1, ST_GeomFromText('POINT(0 0)')),
  (2, ST_GeomFromText('POINT(10 10)')),
  (3, ST_GeomFromText('LINESTRING(0 0, 10 10)'));

