# vector_distance_compare.yy
#
# Cross-engine compare: Percona/MySQL (executor1) vs MariaDB (executor2).
# Uses /*executorN ... */ so each server sees its native function syntax.
#
# Command line:
#   perl gentest.pl \
#     --dsn1=dbi:mysql:host=127.0.0.1:port=<ps>:user=root:database=test \
#     --dsn2=dbi:mysql:host=127.0.0.1:port=<mdb>:user=root:database=test \
#     --grammar=conf/vector_distance/vector_distance_compare.yy \
#     --gendata=conf/vector_distance/vector_distance.zz \
#     --post-gendata-sql=conf/vector_distance/init_vectors_comp.sql \
#     --threads=1 --queries=10000 --duration=300 --sqltrace
#
# SCOPE (shared happy-path only):
#   - Metrics with confirmed MariaDB names: EUCLIDEAN, COSINE
#   - Equal dimensions only (3d/3d, 4d/4d, 8d/8d, 384d/384d)
#   - NULL propagation where both engines return NULL
# Float policy:
#   - Emit FLOOR(GREATEST(0, dist) * 10) / 10 (one decimal). Coarser than
#     cent bins so float32 ULP noise does not flip 0.01 boundaries (e.g.
#     72.7 vs 72.71). GREATEST clamps tiny negative cosine float noise.
#   - Prefer integer/boolean outcomes (relative order, equality flags) where
#     possible -- those catch real logic bugs without IEEE sensitivity.
# Intentionally NOT here:
#   - cosine vs zero vector (expected: Percona NULL, MariaDB 0)
#   - dim-mismatch, wrong arity/type, Percona-only DOT/MANHATTAN/DISTANCE synonym

query:
	select_valid_euclidean | select_valid_euclidean | select_valid_euclidean |
	select_valid_cosine | select_valid_cosine |
	select_valid_384 |
	select_ranking_cosine | select_ranking_cosine | select_ranking_euclidean |
	select_ranking_384 |
	select_aggregate_euclidean | select_aggregate_cosine | select_aggregate_sum_count |
	select_where_euclidean | select_where_cosine | select_where_between |
	select_self_distance | select_self_distance_cosine |
	select_self_is_zero |
	select_commutativity | select_commutativity_cosine |
	select_commutativity_flag |
	select_column_pair | select_column_pair |
	select_literal_pair |
	select_anomaly_comparison | select_anomaly_comparison |
	select_anomaly_random_severity |
	select_relative_closer | select_relative_closer |
	select_metric_order_agree |
	select_case_bucket |
	select_union_lookup |
	select_subquery_filter |
	select_null_propagation |
	select_precision_near_zero |
	select_topk_join_filter | select_topk_cosine_filter |
	select_having_filter |
	select_window_rank | select_cte_filter |
	select_self_join_pairwise | select_self_join_nearest |
	select_where_not_null | select_where_ge_ne |
	select_distinct_bucket |
	select_precision_extreme_magnitude ;

# ---------------------------------------------------------------------------
# Point lookups -- both metrics, both widths
# ---------------------------------------------------------------------------

select_valid_euclidean:
	SELECT id,
		FLOOR(GREATEST(0, (/*executor1 VECTOR_DISTANCE( */ /*executor2 VEC_DISTANCE_EUCLIDEAN( */
		_vector_3d , _vector_3d
		/*executor1 , 'EUCLIDEAN' ) */ /*executor2 ) */)) * 10) / 10 AS d
	FROM vt WHERE id = _existing_id |
	SELECT id,
		FLOOR(GREATEST(0, (/*executor1 VECTOR_DISTANCE( */ /*executor2 VEC_DISTANCE_EUCLIDEAN( */
		_vector_8d , _vector_8d
		/*executor1 , 'EUCLIDEAN' ) */ /*executor2 ) */)) * 10) / 10 AS d
	FROM vt WHERE id = _existing_id ;

select_valid_cosine:
	SELECT id,
		FLOOR(GREATEST(0, (/*executor1 VECTOR_DISTANCE( */ /*executor2 VEC_DISTANCE_COSINE( */
		_vector_3d , _vector_3d
		/*executor1 , 'COSINE' ) */ /*executor2 ) */)) * 10) / 10 AS d
	FROM vt WHERE id = _existing_id |
	SELECT id,
		FLOOR(GREATEST(0, (/*executor1 VECTOR_DISTANCE( */ /*executor2 VEC_DISTANCE_COSINE( */
		_vector_8d , _vector_8d
		/*executor1 , 'COSINE' ) */ /*executor2 ) */)) * 10) / 10 AS d
	FROM vt WHERE id = _existing_id ;

select_valid_384:
	SELECT id,
		FLOOR(GREATEST(0, (/*executor1 VECTOR_DISTANCE( */ /*executor2 VEC_DISTANCE_EUCLIDEAN( */
		v384 , v384
		/*executor1 , 'EUCLIDEAN' ) */ /*executor2 ) */)) * 10) / 10 AS d
	FROM vt WHERE id = _existing_id |
	SELECT id,
		FLOOR(GREATEST(0, (/*executor1 VECTOR_DISTANCE( */ /*executor2 VEC_DISTANCE_COSINE( */
		v384 , v384
		/*executor1 , 'COSINE' ) */ /*executor2 ) */)) * 10) / 10 AS d
	FROM vt WHERE id = _existing_id |
	SELECT id,
		FLOOR(GREATEST(0, (/*executor1 VECTOR_DISTANCE( */ /*executor2 VEC_DISTANCE_EUCLIDEAN( */
		v384 , /*executor1 STRING_TO_VECTOR */ /*executor2 VEC_FromText */(_vector384)
		/*executor1 , 'EUCLIDEAN' ) */ /*executor2 ) */)) * 10) / 10 AS d
	FROM vt WHERE id = _existing_id ;

# ---------------------------------------------------------------------------
# Ranking / aggregates / predicates
# ---------------------------------------------------------------------------

# Ranking compares row *order* only (no distance float in the SELECT list).
select_ranking_cosine:
	SELECT id, label, category
	FROM vt
	ORDER BY
		/*executor1 VECTOR_DISTANCE( */ /*executor2 VEC_DISTANCE_COSINE( */
		v3 , /*executor1 STRING_TO_VECTOR */ /*executor2 VEC_FromText */(_vector3)
		/*executor1 , 'COSINE' ) */ /*executor2 ) */
		_asc_desc ,
		id ASC
	LIMIT _small_limit |
	SELECT id, label, category
	FROM vt
	ORDER BY
		/*executor1 VECTOR_DISTANCE( */ /*executor2 VEC_DISTANCE_COSINE( */
		v8 , /*executor1 STRING_TO_VECTOR */ /*executor2 VEC_FromText */(_vector8)
		/*executor1 , 'COSINE' ) */ /*executor2 ) */
		_asc_desc ,
		id ASC
	LIMIT _small_limit ;

select_ranking_euclidean:
	SELECT id, label, category
	FROM vt
	ORDER BY
		/*executor1 VECTOR_DISTANCE( */ /*executor2 VEC_DISTANCE_EUCLIDEAN( */
		v3 , /*executor1 STRING_TO_VECTOR */ /*executor2 VEC_FromText */(_vector3)
		/*executor1 , 'EUCLIDEAN' ) */ /*executor2 ) */
		_asc_desc ,
		id ASC
	LIMIT _small_limit |
	SELECT id, label, category
	FROM vt
	ORDER BY
		/*executor1 VECTOR_DISTANCE( */ /*executor2 VEC_DISTANCE_EUCLIDEAN( */
		v8 , /*executor1 STRING_TO_VECTOR */ /*executor2 VEC_FromText */(_vector8)
		/*executor1 , 'EUCLIDEAN' ) */ /*executor2 ) */
		_asc_desc ,
		id ASC
	LIMIT _small_limit ;

# Embedding-width ranking (stored v384 only -- avoid huge random literals here)
select_ranking_384:
	SELECT id, label, category
	FROM vt
	ORDER BY
		/*executor1 VECTOR_DISTANCE( */ /*executor2 VEC_DISTANCE_COSINE( */
		v384 , v384
		/*executor1 , 'COSINE' ) */ /*executor2 ) */
		_asc_desc ,
		id ASC
	LIMIT _small_limit |
	SELECT id, label, category
	FROM vt
	ORDER BY
		/*executor1 VECTOR_DISTANCE( */ /*executor2 VEC_DISTANCE_EUCLIDEAN( */
		v384 , v384
		/*executor1 , 'EUCLIDEAN' ) */ /*executor2 ) */
		_asc_desc ,
		id ASC
	LIMIT _small_limit ;

select_aggregate_euclidean:
	SELECT category, FLOOR(GREATEST(0, AVG(
		/*executor1 VECTOR_DISTANCE( */ /*executor2 VEC_DISTANCE_EUCLIDEAN( */
		v3 , /*executor1 STRING_TO_VECTOR */ /*executor2 VEC_FromText */(_vector3)
		/*executor1 , 'EUCLIDEAN' ) */ /*executor2 ) */
	)) * 10) / 10 AS avg_d
	FROM vt GROUP BY category ORDER BY category |
	SELECT category,
		FLOOR(GREATEST(0, MIN(/*executor1 VECTOR_DISTANCE( */ /*executor2 VEC_DISTANCE_EUCLIDEAN( */
			v3 , /*executor1 STRING_TO_VECTOR */ /*executor2 VEC_FromText */(_vector3)
			/*executor1 , 'EUCLIDEAN' ) */ /*executor2 ) */)) * 10) / 10 AS min_d ,
		FLOOR(GREATEST(0, MAX(/*executor1 VECTOR_DISTANCE( */ /*executor2 VEC_DISTANCE_EUCLIDEAN( */
			v3 , /*executor1 STRING_TO_VECTOR */ /*executor2 VEC_FromText */(_vector3)
			/*executor1 , 'EUCLIDEAN' ) */ /*executor2 ) */)) * 10) / 10 AS max_d
	FROM vt GROUP BY category ORDER BY category ;

select_aggregate_cosine:
	SELECT category, FLOOR(GREATEST(0, AVG(
		/*executor1 VECTOR_DISTANCE( */ /*executor2 VEC_DISTANCE_COSINE( */
		v3 , /*executor1 STRING_TO_VECTOR */ /*executor2 VEC_FromText */(_vector3)
		/*executor1 , 'COSINE' ) */ /*executor2 ) */
	)) * 10) / 10 AS avg_d
	FROM vt GROUP BY category ORDER BY category ;

select_aggregate_sum_count:
	SELECT category,
		FLOOR(GREATEST(0, SUM(/*executor1 VECTOR_DISTANCE( */ /*executor2 VEC_DISTANCE_EUCLIDEAN( */
			v3 , /*executor1 STRING_TO_VECTOR */ /*executor2 VEC_FromText */(_vector3)
			/*executor1 , 'EUCLIDEAN' ) */ /*executor2 ) */)) * 10) / 10 AS sum_d ,
		COUNT(*) AS n
	FROM vt GROUP BY category ORDER BY category ;

select_where_euclidean:
	SELECT id FROM vt WHERE
		/*executor1 VECTOR_DISTANCE( */ /*executor2 VEC_DISTANCE_EUCLIDEAN( */
		v3 , /*executor1 STRING_TO_VECTOR */ /*executor2 VEC_FromText */(_vector3)
		/*executor1 , 'EUCLIDEAN' ) */ /*executor2 ) */
		< _threshold
	ORDER BY id ;

select_where_cosine:
	SELECT id FROM vt WHERE
		/*executor1 VECTOR_DISTANCE( */ /*executor2 VEC_DISTANCE_COSINE( */
		v3 , /*executor1 STRING_TO_VECTOR */ /*executor2 VEC_FromText */(_vector3)
		/*executor1 , 'COSINE' ) */ /*executor2 ) */
		< _threshold_cosine
	ORDER BY id ;

select_where_between:
	SELECT id FROM vt WHERE
		/*executor1 VECTOR_DISTANCE( */ /*executor2 VEC_DISTANCE_EUCLIDEAN( */
		v3 , /*executor1 STRING_TO_VECTOR */ /*executor2 VEC_FromText */(_vector3)
		/*executor1 , 'EUCLIDEAN' ) */ /*executor2 ) */
		BETWEEN _threshold_lo AND _threshold_hi
	ORDER BY id ;

select_having_filter:
	SELECT category, FLOOR(GREATEST(0, AVG(
		/*executor1 VECTOR_DISTANCE( */ /*executor2 VEC_DISTANCE_EUCLIDEAN( */
		v3 , /*executor1 STRING_TO_VECTOR */ /*executor2 VEC_FromText */(_vector3)
		/*executor1 , 'EUCLIDEAN' ) */ /*executor2 ) */
	)) * 10) / 10 AS avg_d
	FROM vt
	GROUP BY category
	HAVING avg_d < _threshold_hi
	ORDER BY category ;

select_topk_join_filter:
	SELECT id, label, category
	FROM vt
	WHERE category = _category
	ORDER BY
		/*executor1 VECTOR_DISTANCE( */ /*executor2 VEC_DISTANCE_EUCLIDEAN( */
		v3 , /*executor1 STRING_TO_VECTOR */ /*executor2 VEC_FromText */(_vector3)
		/*executor1 , 'EUCLIDEAN' ) */ /*executor2 ) */
		ASC ,
		id ASC
	LIMIT _small_limit ;

select_topk_cosine_filter:
	SELECT id, label, category
	FROM vt
	WHERE category = _category
	ORDER BY
		/*executor1 VECTOR_DISTANCE( */ /*executor2 VEC_DISTANCE_COSINE( */
		v3 , /*executor1 STRING_TO_VECTOR */ /*executor2 VEC_FromText */(_vector3)
		/*executor1 , 'COSINE' ) */ /*executor2 ) */
		ASC ,
		id ASC
	LIMIT _small_limit ;

# ---------------------------------------------------------------------------
# Algebraic / identity properties
# ---------------------------------------------------------------------------

select_self_distance:
	SELECT id,
		FLOOR(GREATEST(0, (/*executor1 VECTOR_DISTANCE( */ /*executor2 VEC_DISTANCE_EUCLIDEAN( */
		v3 , v3
		/*executor1 , 'EUCLIDEAN' ) */ /*executor2 ) */)) * 10) / 10 AS d_self
	FROM vt WHERE id = _existing_id |
	SELECT id,
		FLOOR(GREATEST(0, (/*executor1 VECTOR_DISTANCE( */ /*executor2 VEC_DISTANCE_EUCLIDEAN( */
		v8 , v8
		/*executor1 , 'EUCLIDEAN' ) */ /*executor2 ) */)) * 10) / 10 AS d_self
	FROM vt WHERE id = _existing_id |
	SELECT id,
		FLOOR(GREATEST(0, (/*executor1 VECTOR_DISTANCE( */ /*executor2 VEC_DISTANCE_EUCLIDEAN( */
		v384 , v384
		/*executor1 , 'EUCLIDEAN' ) */ /*executor2 ) */)) * 10) / 10 AS d_self
	FROM vt WHERE id = _existing_id ;

select_self_distance_cosine:
	SELECT id,
		FLOOR(GREATEST(0, (/*executor1 VECTOR_DISTANCE( */ /*executor2 VEC_DISTANCE_COSINE( */
		v3 , v3
		/*executor1 , 'COSINE' ) */ /*executor2 ) */)) * 10) / 10 AS d_self
	FROM vt WHERE id = _existing_id |
	SELECT id,
		FLOOR(GREATEST(0, (/*executor1 VECTOR_DISTANCE( */ /*executor2 VEC_DISTANCE_COSINE( */
		v8 , v8
		/*executor1 , 'COSINE' ) */ /*executor2 ) */)) * 10) / 10 AS d_self
	FROM vt WHERE id = _existing_id |
	SELECT id,
		FLOOR(GREATEST(0, (/*executor1 VECTOR_DISTANCE( */ /*executor2 VEC_DISTANCE_COSINE( */
		v384 , v384
		/*executor1 , 'COSINE' ) */ /*executor2 ) */)) * 10) / 10 AS d_self
	FROM vt WHERE id = _existing_id ;

# Integer flag: self-distance truncates to 0 (stronger signal than raw float)
select_self_is_zero:
	SELECT id,
		(FLOOR(GREATEST(0, (/*executor1 VECTOR_DISTANCE( */ /*executor2 VEC_DISTANCE_EUCLIDEAN( */
			v3 , v3
			/*executor1 , 'EUCLIDEAN' ) */ /*executor2 ) */)) * 10) = 0) AS euclid_zero ,
		(FLOOR(GREATEST(0, (/*executor1 VECTOR_DISTANCE( */ /*executor2 VEC_DISTANCE_COSINE( */
			v3 , v3
			/*executor1 , 'COSINE' ) */ /*executor2 ) */)) * 10) = 0) AS cosine_zero
	FROM vt WHERE id = _existing_id |
	SELECT id,
		(FLOOR(GREATEST(0, (/*executor1 VECTOR_DISTANCE( */ /*executor2 VEC_DISTANCE_EUCLIDEAN( */
			v8 , v8
			/*executor1 , 'EUCLIDEAN' ) */ /*executor2 ) */)) * 10) = 0) AS euclid_zero ,
		(FLOOR(GREATEST(0, (/*executor1 VECTOR_DISTANCE( */ /*executor2 VEC_DISTANCE_COSINE( */
			v8 , v8
			/*executor1 , 'COSINE' ) */ /*executor2 ) */)) * 10) = 0) AS cosine_zero
	FROM vt WHERE id = _existing_id ;

select_commutativity:
	SELECT id,
		FLOOR(GREATEST(0, (/*executor1 VECTOR_DISTANCE( */ /*executor2 VEC_DISTANCE_EUCLIDEAN( */
		v4_baseline , v4_anomaly_a
		/*executor1 , 'EUCLIDEAN' ) */ /*executor2 ) */)) * 10) / 10 AS d_ab ,
		FLOOR(GREATEST(0, (/*executor1 VECTOR_DISTANCE( */ /*executor2 VEC_DISTANCE_EUCLIDEAN( */
		v4_anomaly_a , v4_baseline
		/*executor1 , 'EUCLIDEAN' ) */ /*executor2 ) */)) * 10) / 10 AS d_ba
	FROM vt WHERE id = _existing_id ;

select_commutativity_cosine:
	SELECT id,
		FLOOR(GREATEST(0, (/*executor1 VECTOR_DISTANCE( */ /*executor2 VEC_DISTANCE_COSINE( */
		v4_baseline , v4_anomaly_b
		/*executor1 , 'COSINE' ) */ /*executor2 ) */)) * 10) / 10 AS d_ab ,
		FLOOR(GREATEST(0, (/*executor1 VECTOR_DISTANCE( */ /*executor2 VEC_DISTANCE_COSINE( */
		v4_anomaly_b , v4_baseline
		/*executor1 , 'COSINE' ) */ /*executor2 ) */)) * 10) / 10 AS d_ba
	FROM vt WHERE id = _existing_id ;

# Boolean commutativity (integer 0/1) -- flags real asymmetry without float dump noise
select_commutativity_flag:
	SELECT id,
		(FLOOR(GREATEST(0, (/*executor1 VECTOR_DISTANCE( */ /*executor2 VEC_DISTANCE_EUCLIDEAN( */
			v4_baseline , v4_anomaly_a
			/*executor1 , 'EUCLIDEAN' ) */ /*executor2 ) */)) * 10) =
		 FLOOR(GREATEST(0, (/*executor1 VECTOR_DISTANCE( */ /*executor2 VEC_DISTANCE_EUCLIDEAN( */
			v4_anomaly_a , v4_baseline
			/*executor1 , 'EUCLIDEAN' ) */ /*executor2 ) */)) * 10)) AS euclid_symmetric ,
		(FLOOR(GREATEST(0, (/*executor1 VECTOR_DISTANCE( */ /*executor2 VEC_DISTANCE_COSINE( */
			v4_baseline , v4_anomaly_b
			/*executor1 , 'COSINE' ) */ /*executor2 ) */)) * 10) =
		 FLOOR(GREATEST(0, (/*executor1 VECTOR_DISTANCE( */ /*executor2 VEC_DISTANCE_COSINE( */
			v4_anomaly_b , v4_baseline
			/*executor1 , 'COSINE' ) */ /*executor2 ) */)) * 10)) AS cosine_symmetric
	FROM vt WHERE id = _existing_id ;

select_column_pair:
	SELECT id,
		FLOOR(GREATEST(0, (/*executor1 VECTOR_DISTANCE( */ /*executor2 VEC_DISTANCE_EUCLIDEAN( */
		v4_baseline , v4_anomaly_a
		/*executor1 , 'EUCLIDEAN' ) */ /*executor2 ) */)) * 10) / 10 AS d_euclid ,
		FLOOR(GREATEST(0, (/*executor1 VECTOR_DISTANCE( */ /*executor2 VEC_DISTANCE_COSINE( */
		v4_baseline , v4_anomaly_a
		/*executor1 , 'COSINE' ) */ /*executor2 ) */)) * 10) / 10 AS d_cosine
	FROM vt WHERE id = _existing_id |
	SELECT id,
		FLOOR(GREATEST(0, (/*executor1 VECTOR_DISTANCE( */ /*executor2 VEC_DISTANCE_EUCLIDEAN( */
		v4_baseline , v4_anomaly_b
		/*executor1 , 'EUCLIDEAN' ) */ /*executor2 ) */)) * 10) / 10 AS d_euclid ,
		FLOOR(GREATEST(0, (/*executor1 VECTOR_DISTANCE( */ /*executor2 VEC_DISTANCE_COSINE( */
		v4_baseline , v4_anomaly_b
		/*executor1 , 'COSINE' ) */ /*executor2 ) */)) * 10) / 10 AS d_cosine
	FROM vt WHERE id = _existing_id |
	SELECT id,
		FLOOR(GREATEST(0, (/*executor1 VECTOR_DISTANCE( */ /*executor2 VEC_DISTANCE_EUCLIDEAN( */
		v4_anomaly_a , v4_anomaly_b
		/*executor1 , 'EUCLIDEAN' ) */ /*executor2 ) */)) * 10) / 10 AS d_euclid ,
		FLOOR(GREATEST(0, (/*executor1 VECTOR_DISTANCE( */ /*executor2 VEC_DISTANCE_COSINE( */
		v4_anomaly_a , v4_anomaly_b
		/*executor1 , 'COSINE' ) */ /*executor2 ) */)) * 10) / 10 AS d_cosine
	FROM vt WHERE id = _existing_id ;

# Two independent equal-width literals (both engines see identical SQL text)
select_literal_pair:
	SELECT
		FLOOR(GREATEST(0, (/*executor1 VECTOR_DISTANCE( */ /*executor2 VEC_DISTANCE_EUCLIDEAN( */
		/*executor1 STRING_TO_VECTOR */ /*executor2 VEC_FromText */(_vector3) ,
		/*executor1 STRING_TO_VECTOR */ /*executor2 VEC_FromText */(_vector3)
		/*executor1 , 'EUCLIDEAN' ) */ /*executor2 ) */)) * 10) / 10 AS d
	FROM vt LIMIT 1 |
	SELECT
		FLOOR(GREATEST(0, (/*executor1 VECTOR_DISTANCE( */ /*executor2 VEC_DISTANCE_COSINE( */
		/*executor1 STRING_TO_VECTOR */ /*executor2 VEC_FromText */(_vector8) ,
		/*executor1 STRING_TO_VECTOR */ /*executor2 VEC_FromText */(_vector8)
		/*executor1 , 'COSINE' ) */ /*executor2 ) */)) * 10) / 10 AS d
	FROM vt LIMIT 1 ;

# ---------------------------------------------------------------------------
# Anomaly / relative-order coverage (logic bugs over float noise)
# ---------------------------------------------------------------------------

select_anomaly_comparison:
	SELECT
		FLOOR(GREATEST(0, (/*executor1 VECTOR_DISTANCE( */ /*executor2 VEC_DISTANCE_COSINE( */
		v4_baseline , v4_anomaly_a
		/*executor1 , 'COSINE' ) */ /*executor2 ) */)) * 10) / 10 AS a_cosine ,
		FLOOR(GREATEST(0, (/*executor1 VECTOR_DISTANCE( */ /*executor2 VEC_DISTANCE_EUCLIDEAN( */
		v4_baseline , v4_anomaly_a
		/*executor1 , 'EUCLIDEAN' ) */ /*executor2 ) */)) * 10) / 10 AS a_euclidean ,
		FLOOR(GREATEST(0, (/*executor1 VECTOR_DISTANCE( */ /*executor2 VEC_DISTANCE_COSINE( */
		v4_baseline , v4_anomaly_b
		/*executor1 , 'COSINE' ) */ /*executor2 ) */)) * 10) / 10 AS b_cosine ,
		FLOOR(GREATEST(0, (/*executor1 VECTOR_DISTANCE( */ /*executor2 VEC_DISTANCE_EUCLIDEAN( */
		v4_baseline , v4_anomaly_b
		/*executor1 , 'EUCLIDEAN' ) */ /*executor2 ) */)) * 10) / 10 AS b_euclidean
	FROM vt WHERE id = _existing_id ;

# Shared perl expansion so cosine/euclidean see the same anomaly literal per pair
select_anomaly_random_severity:
	SELECT id , _anomaly_a_dual_metric , _anomaly_b_dual_metric
	FROM vt WHERE id = _existing_id ;

# Which stored anomaly is closer under each metric? Integer 0/1 -- high-signal
select_relative_closer:
	SELECT id,
		(/*executor1 VECTOR_DISTANCE( */ /*executor2 VEC_DISTANCE_EUCLIDEAN( */
			v4_baseline , v4_anomaly_a
			/*executor1 , 'EUCLIDEAN' ) */ /*executor2 ) */ <
		 /*executor1 VECTOR_DISTANCE( */ /*executor2 VEC_DISTANCE_EUCLIDEAN( */
			v4_baseline , v4_anomaly_b
			/*executor1 , 'EUCLIDEAN' ) */ /*executor2 ) */) AS a_closer_euclid ,
		(/*executor1 VECTOR_DISTANCE( */ /*executor2 VEC_DISTANCE_COSINE( */
			v4_baseline , v4_anomaly_a
			/*executor1 , 'COSINE' ) */ /*executor2 ) */ <
		 /*executor1 VECTOR_DISTANCE( */ /*executor2 VEC_DISTANCE_COSINE( */
			v4_baseline , v4_anomaly_b
			/*executor1 , 'COSINE' ) */ /*executor2 ) */) AS a_closer_cosine
	FROM vt WHERE id = _existing_id ;

# Do EUCLIDEAN and COSINE agree on which anomaly is closer? (0/1)
select_metric_order_agree:
	SELECT id,
		((/*executor1 VECTOR_DISTANCE( */ /*executor2 VEC_DISTANCE_EUCLIDEAN( */
			v4_baseline , v4_anomaly_a
			/*executor1 , 'EUCLIDEAN' ) */ /*executor2 ) */ <
		  /*executor1 VECTOR_DISTANCE( */ /*executor2 VEC_DISTANCE_EUCLIDEAN( */
			v4_baseline , v4_anomaly_b
			/*executor1 , 'EUCLIDEAN' ) */ /*executor2 ) */) =
		 (/*executor1 VECTOR_DISTANCE( */ /*executor2 VEC_DISTANCE_COSINE( */
			v4_baseline , v4_anomaly_a
			/*executor1 , 'COSINE' ) */ /*executor2 ) */ <
		  /*executor1 VECTOR_DISTANCE( */ /*executor2 VEC_DISTANCE_COSINE( */
			v4_baseline , v4_anomaly_b
			/*executor1 , 'COSINE' ) */ /*executor2 ) */)) AS metrics_agree
	FROM vt WHERE id = _existing_id ;

# Discrete distance buckets via CASE (stable integer labels)
select_case_bucket:
	SELECT id,
		CASE
			WHEN /*executor1 VECTOR_DISTANCE( */ /*executor2 VEC_DISTANCE_EUCLIDEAN( */
				v4_baseline , v4_anomaly_a
				/*executor1 , 'EUCLIDEAN' ) */ /*executor2 ) */ < 10 THEN 0
			WHEN /*executor1 VECTOR_DISTANCE( */ /*executor2 VEC_DISTANCE_EUCLIDEAN( */
				v4_baseline , v4_anomaly_a
				/*executor1 , 'EUCLIDEAN' ) */ /*executor2 ) */ < 50 THEN 1
			WHEN /*executor1 VECTOR_DISTANCE( */ /*executor2 VEC_DISTANCE_EUCLIDEAN( */
				v4_baseline , v4_anomaly_a
				/*executor1 , 'EUCLIDEAN' ) */ /*executor2 ) */ < 100 THEN 2
			ELSE 3
		END AS euclid_bucket ,
		CASE
			WHEN /*executor1 VECTOR_DISTANCE( */ /*executor2 VEC_DISTANCE_COSINE( */
				v4_baseline , v4_anomaly_b
				/*executor1 , 'COSINE' ) */ /*executor2 ) */ < 0.1 THEN 0
			WHEN /*executor1 VECTOR_DISTANCE( */ /*executor2 VEC_DISTANCE_COSINE( */
				v4_baseline , v4_anomaly_b
				/*executor1 , 'COSINE' ) */ /*executor2 ) */ < 0.5 THEN 1
			WHEN /*executor1 VECTOR_DISTANCE( */ /*executor2 VEC_DISTANCE_COSINE( */
				v4_baseline , v4_anomaly_b
				/*executor1 , 'COSINE' ) */ /*executor2 ) */ < 1.0 THEN 2
			ELSE 3
		END AS cosine_bucket
	FROM vt WHERE id = _existing_id ;

# UNION of metric lookups (shape + values must match across engines)
select_union_lookup:
	SELECT 'E' AS metric, id,
		FLOOR(GREATEST(0, (/*executor1 VECTOR_DISTANCE( */ /*executor2 VEC_DISTANCE_EUCLIDEAN( */
		v3 , v3
		/*executor1 , 'EUCLIDEAN' ) */ /*executor2 ) */)) * 10) / 10 AS d
	FROM vt WHERE id = _existing_id
	UNION ALL
	SELECT 'C' AS metric, id,
		FLOOR(GREATEST(0, (/*executor1 VECTOR_DISTANCE( */ /*executor2 VEC_DISTANCE_COSINE( */
		v3 , v3
		/*executor1 , 'COSINE' ) */ /*executor2 ) */)) * 10) / 10 AS d
	FROM vt WHERE id = _existing_id
	ORDER BY metric , id ;

# Distance predicate inside a subquery / derived table
select_subquery_filter:
	SELECT id, label, category FROM vt
	WHERE id IN (
		SELECT id FROM vt
		WHERE /*executor1 VECTOR_DISTANCE( */ /*executor2 VEC_DISTANCE_EUCLIDEAN( */
			v3 , /*executor1 STRING_TO_VECTOR */ /*executor2 VEC_FromText */(_vector3)
			/*executor1 , 'EUCLIDEAN' ) */ /*executor2 ) */
			< _threshold
	)
	ORDER BY id |
	SELECT id, label FROM vt
	WHERE category IN (
		SELECT category FROM vt
		GROUP BY category
		HAVING MIN(/*executor1 VECTOR_DISTANCE( */ /*executor2 VEC_DISTANCE_COSINE( */
			v3 , /*executor1 STRING_TO_VECTOR */ /*executor2 VEC_FromText */(_vector3)
			/*executor1 , 'COSINE' ) */ /*executor2 ) */) < _threshold_cosine
	)
	ORDER BY id ;

# ---------------------------------------------------------------------------
# Shared NULL / precision edge behavior
# ---------------------------------------------------------------------------

select_null_propagation:
	SELECT
		/*executor1 VECTOR_DISTANCE( */ /*executor2 VEC_DISTANCE_EUCLIDEAN( */
		NULL , v3
		/*executor1 , 'EUCLIDEAN' ) */ /*executor2 ) */
		AS d
	FROM vt WHERE id = _existing_id |
	SELECT
		/*executor1 VECTOR_DISTANCE( */ /*executor2 VEC_DISTANCE_EUCLIDEAN( */
		v3 , NULL
		/*executor1 , 'EUCLIDEAN' ) */ /*executor2 ) */
		AS d
	FROM vt WHERE id = _existing_id |
	SELECT
		/*executor1 VECTOR_DISTANCE( */ /*executor2 VEC_DISTANCE_COSINE( */
		NULL , NULL
		/*executor1 , 'COSINE' ) */ /*executor2 ) */
		AS d |
	SELECT
		/*executor1 VECTOR_DISTANCE( */ /*executor2 VEC_DISTANCE_COSINE( */
		NULL , v3
		/*executor1 , 'COSINE' ) */ /*executor2 ) */
		AS d
	FROM vt WHERE id = _existing_id |
	SELECT
		/*executor1 VECTOR_DISTANCE( */ /*executor2 VEC_DISTANCE_COSINE( */
		v3 , NULL
		/*executor1 , 'COSINE' ) */ /*executor2 ) */
		AS d
	FROM vt WHERE id = _existing_id ;

# Identical high-precision literals: both engines should report near-zero.
# Integer flag (FLOOR at 1e6 == 0) surfaces real float32 gaps without ROUND ties.
select_precision_near_zero:
	SELECT
		(FLOOR(GREATEST(0, (/*executor1 VECTOR_DISTANCE( */ /*executor2 VEC_DISTANCE_EUCLIDEAN( */
		_hp_identical_pair
		/*executor1 , 'EUCLIDEAN' ) */ /*executor2 ) */)) * 1000000) = 0) AS near_zero
	FROM vt LIMIT 1 ;

# Identical large-magnitude literals: self-distance should still be zero once
# float32 rounding is happening at scale (1e6..1e12), not just near the origin.
# Complements select_precision_near_zero, which only stresses values in [-1,1].
select_precision_extreme_magnitude:
	SELECT
		(FLOOR(GREATEST(0, (/*executor1 VECTOR_DISTANCE( */ /*executor2 VEC_DISTANCE_EUCLIDEAN( */
		_extreme_identical_pair
		/*executor1 , 'EUCLIDEAN' ) */ /*executor2 ) */))) = 0) AS near_zero_at_scale
	FROM vt LIMIT 1 ;

# ---------------------------------------------------------------------------
# Modern SQL surface: window functions, CTEs, self-joins
# ---------------------------------------------------------------------------

# Window function over a vector-distance ORDER BY -- distinct code path from
# plain ORDER BY ranking above (query-level sort vs. windowed sort).
select_window_rank:
	SELECT id, label,
		RANK() OVER (ORDER BY
			/*executor1 VECTOR_DISTANCE( */ /*executor2 VEC_DISTANCE_EUCLIDEAN( */
			v3 , /*executor1 STRING_TO_VECTOR */ /*executor2 VEC_FromText */(_vector3)
			/*executor1 , 'EUCLIDEAN' ) */ /*executor2 ) */
			ASC) AS rnk
	FROM vt
	ORDER BY rnk , id
	LIMIT _small_limit ;

# CTE: distance computed in a WITH clause, filtered in the outer query --
# a distinct code path from the bare WHERE and derived-subquery cases above.
select_cte_filter:
	WITH d AS (
		SELECT id, label, category,
			/*executor1 VECTOR_DISTANCE( */ /*executor2 VEC_DISTANCE_COSINE( */
			v3 , /*executor1 STRING_TO_VECTOR */ /*executor2 VEC_FromText */(_vector3)
			/*executor1 , 'COSINE' ) */ /*executor2 ) */
			AS dist
		FROM vt
	)
	SELECT id, label, category FROM d
	WHERE dist < _threshold_cosine
	ORDER BY id ;

# Self-join: pairwise distances between distinct stored rows (column-to-column
# via a join), instead of stored-column-vs-literal like every query above.
select_self_join_pairwise:
	SELECT a.id AS id_a, b.id AS id_b,
		FLOOR(GREATEST(0, (/*executor1 VECTOR_DISTANCE( */ /*executor2 VEC_DISTANCE_EUCLIDEAN( */
		a.v3 , b.v3
		/*executor1 , 'EUCLIDEAN' ) */ /*executor2 ) */)) * 10) / 10 AS d
	FROM vt a JOIN vt b ON a.id < b.id
	ORDER BY id_a , id_b
	LIMIT _small_limit ;

# Nearest-neighbor per row via correlated subquery -- the actual query shape
# most similarity-search use cases run.
select_self_join_nearest:
	SELECT a.id,
		(SELECT b.id FROM vt b WHERE b.id <> a.id
			ORDER BY /*executor1 VECTOR_DISTANCE( */ /*executor2 VEC_DISTANCE_EUCLIDEAN( */
				a.v3 , b.v3
				/*executor1 , 'EUCLIDEAN' ) */ /*executor2 ) */ ASC , b.id ASC
			LIMIT 1) AS nearest_id
	FROM vt a
	ORDER BY a.id ;

# ---------------------------------------------------------------------------
# Additional predicate operators (only '<' and BETWEEN are covered above)
# ---------------------------------------------------------------------------

select_where_not_null:
	SELECT id FROM vt WHERE
		/*executor1 VECTOR_DISTANCE( */ /*executor2 VEC_DISTANCE_EUCLIDEAN( */
		v3 , /*executor1 STRING_TO_VECTOR */ /*executor2 VEC_FromText */(_vector3)
		/*executor1 , 'EUCLIDEAN' ) */ /*executor2 ) */
		IS NOT NULL
	ORDER BY id ;

select_where_ge_ne:
	SELECT id FROM vt WHERE
		/*executor1 VECTOR_DISTANCE( */ /*executor2 VEC_DISTANCE_EUCLIDEAN( */
		v3 , /*executor1 STRING_TO_VECTOR */ /*executor2 VEC_FromText */(_vector3)
		/*executor1 , 'EUCLIDEAN' ) */ /*executor2 ) */
		>= _threshold
	ORDER BY id |
	SELECT id FROM vt WHERE
		/*executor1 VECTOR_DISTANCE( */ /*executor2 VEC_DISTANCE_COSINE( */
		v3 , /*executor1 STRING_TO_VECTOR */ /*executor2 VEC_FromText */(_vector3)
		/*executor1 , 'COSINE' ) */ /*executor2 ) */
		!= _threshold_cosine
	ORDER BY id ;

select_distinct_bucket:
	SELECT DISTINCT
		(FLOOR(GREATEST(0, (/*executor1 VECTOR_DISTANCE( */ /*executor2 VEC_DISTANCE_EUCLIDEAN( */
		v4_baseline , v4_anomaly_a
		/*executor1 , 'EUCLIDEAN' ) */ /*executor2 ) */)) * 10) / 10 ) AS d
	FROM vt
	ORDER BY d ;

# ---------------------------------------------------------------------------
# Token / terminal rules -- equal-width sources only
# ---------------------------------------------------------------------------

_vector_3d:
	v3 | /*executor1 STRING_TO_VECTOR */ /*executor2 VEC_FromText */(_vector3) ;

_vector_8d:
	v8 | /*executor1 STRING_TO_VECTOR */ /*executor2 VEC_FromText */(_vector8) ;

_vector3:
	{ "'[" . join(',', map { sprintf('%.4f', (rand() * 200) - 100) } (1..3)) . "]'" } ;

_vector8:
	{ "'[" . join(',', map { sprintf('%.4f', (rand() * 200) - 100) } (1..8)) . "]'" } ;

_vector384:
	{ "'[" . join(',', map { sprintf('%.4f', (rand() * 2) - 1) } (1..384)) . "]'" } ;

# One expansion -> both distance args share the same high-precision text.
# Keep as a single line: a ';' inside a multi-line { } block ends the grammar rule.
_hp_identical_pair:
	{ my $s = "'[" . join(',', map { sprintf('%.12f', (rand() * 2) - 1) } (1..3)) . "]'"; "/*executor1 STRING_TO_VECTOR */ /*executor2 VEC_FromText */($s) , /*executor1 STRING_TO_VECTOR */ /*executor2 VEC_FromText */($s)" } ;

# One expansion -> both distance args share the same large-magnitude text, at
# a random scale in [1e6, 1e12], to check self-distance-is-zero still holds
# once float32 rounding is happening at scale rather than near the origin.
_extreme_identical_pair:
	{ my $scale = (1e6, 1e9, 1e12)[int(rand(3))]; my $s = "'[" . join(',', map { sprintf('%.4f', ((rand() * 2) - 1) * $scale) } (1..3)) . "]'"; "/*executor1 STRING_TO_VECTOR */ /*executor2 VEC_FromText */($s) , /*executor1 STRING_TO_VECTOR */ /*executor2 VEC_FromText */($s)" } ;

# One expansion emits both COSINE and EUCLIDEAN columns for the same Type-A literal.
_anomaly_a_dual_metric:
	{ my $s = 0.5 + rand() * 2.5; my $lit = "'[" . join(',', map { sprintf('%.4f', $_ * $s) } (50,55,10,45)) . "]'"; my $a = "/*executor1 STRING_TO_VECTOR */ /*executor2 VEC_FromText */($lit)"; "FLOOR(GREATEST(0, (/*executor1 VECTOR_DISTANCE( */ /*executor2 VEC_DISTANCE_COSINE( */ v4_baseline , $a /*executor1 , 'COSINE' ) */ /*executor2 ) */)) * 10) / 10 AS a_cosine , FLOOR(GREATEST(0, (/*executor1 VECTOR_DISTANCE( */ /*executor2 VEC_DISTANCE_EUCLIDEAN( */ v4_baseline , $a /*executor1 , 'EUCLIDEAN' ) */ /*executor2 ) */)) * 10) / 10 AS a_euclidean" } ;

# One expansion emits both COSINE and EUCLIDEAN columns for the same Type-B literal.
_anomaly_b_dual_metric:
	{ my @v = (50,55,10,45); $v[int(rand(4))] += 20 + rand() * 80; my $lit = "'[" . join(',', map { sprintf('%.4f', $_) } @v) . "]'"; my $a = "/*executor1 STRING_TO_VECTOR */ /*executor2 VEC_FromText */($lit)"; "FLOOR(GREATEST(0, (/*executor1 VECTOR_DISTANCE( */ /*executor2 VEC_DISTANCE_COSINE( */ v4_baseline , $a /*executor1 , 'COSINE' ) */ /*executor2 ) */)) * 10) / 10 AS b_cosine , FLOOR(GREATEST(0, (/*executor1 VECTOR_DISTANCE( */ /*executor2 VEC_DISTANCE_EUCLIDEAN( */ v4_baseline , $a /*executor1 , 'EUCLIDEAN' ) */ /*executor2 ) */)) * 10) / 10 AS b_euclidean" } ;

_existing_id:
	1 | 2 | 3 | 4 | 5 | 10 | 20 | 50 ;

_category:
	'technology' | 'fruit' | 'weather' | 'vehicles' ;

_small_limit:
	1 | 3 | 5 | 10 ;

_asc_desc:
	ASC | DESC ;

_threshold:
	0 | 1 | 5 | 10 | 50 | 100 ;

_threshold_lo:
	0 | 1 | 5 | 10 ;

_threshold_hi:
	50 | 100 | 150 | 200 ;

_threshold_cosine:
	0 | 0.1 | 0.5 | 1 | 1.5 | 2 ;
