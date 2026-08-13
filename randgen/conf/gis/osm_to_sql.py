#!/usr/bin/env python3
import json
import sys
import argparse
import requests
import osm2geojson
from typing import List

def coordinates_to_wkt_point(coords: List[float]) -> str:
    return f"{coords[0]} {coords[1]}"

def coordinates_to_wkt_linestring(coords: List[List[float]]) -> str:
    points = ", ".join(f"{c[0]} {c[1]}" for c in coords)
    return f"LINESTRING({points})"

def coordinates_to_wkt_polygon(coords: List[List[List[float]]]) -> str:
    rings = []
    for ring in coords:
        points = ", ".join(f"{c[0]} {c[1]}" for c in ring)
        rings.append(f"({points})")
    return f"POLYGON({', '.join(rings)})"

def geojson_to_wkt(geojson: dict) -> str:
    geom_type = geojson.get("type")
    coords = geojson.get("coordinates")
    if geom_type == "Point":
        return f"POINT({coordinates_to_wkt_point(coords)})"
    elif geom_type == "LineString":
        return coordinates_to_wkt_linestring(coords)
    elif geom_type == "Polygon":
        return coordinates_to_wkt_polygon(coords)
    # Note: Multi-geometries can be added here from your original script if needed
    else:
        raise ValueError(f"Unsupported geometry type: {geom_type}")

def generate_insert_statement(pk: int, wkt: str, table_name: str, use_st_prefix: bool) -> str:
    func_name = "ST_GeomFromText" if use_st_prefix else "GeomFromText"
    return (
        f"INSERT INTO {table_name} (pk, linestring_key, linestring_nokey) "
        f"VALUES ({pk}, {func_name}('{wkt}'), {func_name}('{wkt}'));"
    )

# --- OSM EXTRACTION LOGIC ---

def fetch_osm_data_by_city(city_name: str):
    """Fetch all highway data for a specific city via Overpass API using POST."""
    overpass_url = "https://overpass-api.de/api/interpreter"
    
    # Identify your script to avoid 406/403 errors
    headers = {
        'User-Agent': 'OSMToSQLConverter/1.0',
        'Content-Type': 'application/x-www-form-urlencoded'
    }
    
    # increased timeout to 90 for dense cities like Paris
    query = f"""
    [out:json][timeout:90];
    area[name="{city_name}"]->.searchArea;
    (
      way["highway"](area.searchArea);
    );
    out geom;
    """
    
    print(f"Querying Overpass API for city: {city_name}...", file=sys.stderr)
    
    # Send as POST data, not as URL parameters
    response = requests.post(overpass_url, data={'data': query}, headers=headers)
    
    if response.status_code != 200:
        print(f"API Error {response.status_code}: {response.text}", file=sys.stderr)
        response.raise_for_status()
    
    return osm2geojson.json2geojson(response.json())


def main():
    parser = argparse.ArgumentParser(description="Extract OSM data by city and convert to SQL")
    parser.add_argument("city", help="Name of the city (e.g., 'San Francisco')")
    parser.add_argument("output", help="Output SQL file")
    parser.add_argument("--table", default="linestring", help="Table name")
    parser.add_argument("--mysql-version", choices=["5.7", "8.0"], default="8.0")
    
    args = parser.parse_args()
    use_st_prefix = args.mysql_version == "8.0"

    try:
        # 1. Fetch and Convert to GeoJSON
        geojson_data = fetch_osm_data_by_city(args.city)
        features = geojson_data.get("features", [])

        if not features:
            print(f"No highway features found for '{args.city}'", file=sys.stderr)
            return

        # 2. Process and Write SQL
        with open(args.output, 'w', encoding='utf-8') as f:
            f.write(f"DROP TABLE IF EXISTS {args.table};\n")
            f.write(
                f"CREATE TABLE {args.table} ("
                f"pk INTEGER NOT NULL PRIMARY KEY, "
                f"linestring_key GEOMETRY NOT NULL, "
                f"linestring_nokey GEOMETRY NOT NULL, "
                f"SPATIAL INDEX(linestring_key), "
                f"SPATIAL INDEX(linestring_nokey)"
                f") ENGINE=InnoDB;\n"
            )

            pk = 1
            for feature in features:
                geometry = feature.get("geometry")
                if geometry and geometry.get("type") in ["Point", "LineString", "Polygon"]:
                    try:
                        wkt = geojson_to_wkt(geometry)
                        sql = generate_insert_statement(pk, wkt, args.table, use_st_prefix)
                        f.write(sql + "\n")
                        pk += 1
                    except Exception:
                        continue # Skip unsupported or complex geometries

        print(f"Done! Successfully wrote {pk-1} features to {args.output}", file=sys.stderr)

    except Exception as e:
        print(f"Error: {e}", file=sys.stderr)
        sys.exit(1)

if __name__ == "__main__":
    main()
