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
# Intentionally NOT here:
#   - cosine vs zero vector (expected: Percona NULL, MariaDB 0)
#   - dim-mismatch, wrong arity/type, Percona-only DOT/MANHATTAN/DISTANCE synonym

query:
	select_valid_euclidean | select_valid_euclidean | select_valid_euclidean |
	select_valid_cosine | select_valid_cosine |
	select_valid_384 |
	select_ranking_cosine | select_ranking_cosine | select_ranking_euclidean |
	select_aggregate_euclidean | select_aggregate_cosine | select_aggregate_sum_count |
	select_where_euclidean | select_where_cosine | select_where_between |
	select_self_distance | select_self_distance_cosine |
	select_commutativity | select_commutativity_cosine |
	select_column_pair | select_column_pair |
	select_literal_pair |
	select_anomaly_comparison | select_anomaly_comparison |
	select_anomaly_random_severity |
	select_null_propagation |
	select_precision_truncation |
	select_topk_join_filter | select_topk_cosine_filter |
	select_having_filter ;

# ---------------------------------------------------------------------------
# Point lookups -- both metrics, both widths
# ---------------------------------------------------------------------------

select_valid_euclidean:
	SELECT id,
		ROUND(/*executor1 VECTOR_DISTANCE( */ /*executor2 VEC_DISTANCE_EUCLIDEAN( */
		_vector_3d , _vector_3d
		/*executor1 , 'EUCLIDEAN' ) */ /*executor2 ) */, 2) AS d
	FROM vt WHERE id = _existing_id |
	SELECT id,
		ROUND(/*executor1 VECTOR_DISTANCE( */ /*executor2 VEC_DISTANCE_EUCLIDEAN( */
		_vector_8d , _vector_8d
		/*executor1 , 'EUCLIDEAN' ) */ /*executor2 ) */, 2) AS d
	FROM vt WHERE id = _existing_id ;

select_valid_cosine:
	SELECT id,
		ROUND(/*executor1 VECTOR_DISTANCE( */ /*executor2 VEC_DISTANCE_COSINE( */
		_vector_3d , _vector_3d
		/*executor1 , 'COSINE' ) */ /*executor2 ) */, 2) AS d
	FROM vt WHERE id = _existing_id |
	SELECT id,
		ROUND(/*executor1 VECTOR_DISTANCE( */ /*executor2 VEC_DISTANCE_COSINE( */
		_vector_8d , _vector_8d
		/*executor1 , 'COSINE' ) */ /*executor2 ) */, 2) AS d
	FROM vt WHERE id = _existing_id ;

# Realistic embedding width (all rows now hold genuine 384-d vectors)
select_valid_384:
	SELECT id,
		ROUND(/*executor1 VECTOR_DISTANCE( */ /*executor2 VEC_DISTANCE_EUCLIDEAN( */
		v384 , v384
		/*executor1 , 'EUCLIDEAN' ) */ /*executor2 ) */, 2) AS d
	FROM vt WHERE id = _existing_id |
	SELECT id,
		ROUND(/*executor1 VECTOR_DISTANCE( */ /*executor2 VEC_DISTANCE_COSINE( */
		v384 , v384
		/*executor1 , 'COSINE' ) */ /*executor2 ) */, 2) AS d
	FROM vt WHERE id = _existing_id |
	SELECT id,
		ROUND(/*executor1 VECTOR_DISTANCE( */ /*executor2 VEC_DISTANCE_EUCLIDEAN( */
		v384 , /*executor1 STRING_TO_VECTOR */ /*executor2 VEC_FromText */(_vector384)
		/*executor1 , 'EUCLIDEAN' ) */ /*executor2 ) */, 2) AS d
	FROM vt WHERE id = _existing_id ;

# ---------------------------------------------------------------------------
# Ranking / aggregates / predicates
# ---------------------------------------------------------------------------

# Ranking compares row *order* only (no distance float in the SELECT list).
# Dumping raw floats causes false ResultsetComparator diffs from tiny IEEE diffs.
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

# Float compare: ROUND(..., 2) everywhere — ROUND(3+) still flips across engines.
select_aggregate_euclidean:
	SELECT category, ROUND(AVG(
		/*executor1 VECTOR_DISTANCE( */ /*executor2 VEC_DISTANCE_EUCLIDEAN( */
		v3 , /*executor1 STRING_TO_VECTOR */ /*executor2 VEC_FromText */(_vector3)
		/*executor1 , 'EUCLIDEAN' ) */ /*executor2 ) */
	), 2) AS avg_d
	FROM vt GROUP BY category ORDER BY category |
	SELECT category,
		ROUND(MIN(/*executor1 VECTOR_DISTANCE( */ /*executor2 VEC_DISTANCE_EUCLIDEAN( */
			v3 , /*executor1 STRING_TO_VECTOR */ /*executor2 VEC_FromText */(_vector3)
			/*executor1 , 'EUCLIDEAN' ) */ /*executor2 ) */), 2) AS min_d ,
		ROUND(MAX(/*executor1 VECTOR_DISTANCE( */ /*executor2 VEC_DISTANCE_EUCLIDEAN( */
			v3 , /*executor1 STRING_TO_VECTOR */ /*executor2 VEC_FromText */(_vector3)
			/*executor1 , 'EUCLIDEAN' ) */ /*executor2 ) */), 2) AS max_d
	FROM vt GROUP BY category ORDER BY category ;

select_aggregate_cosine:
	SELECT category, ROUND(AVG(
		/*executor1 VECTOR_DISTANCE( */ /*executor2 VEC_DISTANCE_COSINE( */
		v3 , /*executor1 STRING_TO_VECTOR */ /*executor2 VEC_FromText */(_vector3)
		/*executor1 , 'COSINE' ) */ /*executor2 ) */
	), 2) AS avg_d
	FROM vt GROUP BY category ORDER BY category ;

select_aggregate_sum_count:
	SELECT category,
		ROUND(SUM(/*executor1 VECTOR_DISTANCE( */ /*executor2 VEC_DISTANCE_EUCLIDEAN( */
			v3 , /*executor1 STRING_TO_VECTOR */ /*executor2 VEC_FromText */(_vector3)
			/*executor1 , 'EUCLIDEAN' ) */ /*executor2 ) */), 2) AS sum_d ,
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
	SELECT category, ROUND(AVG(
		/*executor1 VECTOR_DISTANCE( */ /*executor2 VEC_DISTANCE_EUCLIDEAN( */
		v3 , /*executor1 STRING_TO_VECTOR */ /*executor2 VEC_FromText */(_vector3)
		/*executor1 , 'EUCLIDEAN' ) */ /*executor2 ) */
	), 2) AS avg_d
	FROM vt
	GROUP BY category
	HAVING avg_d < _threshold_hi
	ORDER BY category ;

# Hybrid: filter by category then rank (relational + vector in one query)
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

# dist(v,v) should be ~0 for euclidean on both engines
select_self_distance:
	SELECT id,
		ROUND(/*executor1 VECTOR_DISTANCE( */ /*executor2 VEC_DISTANCE_EUCLIDEAN( */
		v3 , v3
		/*executor1 , 'EUCLIDEAN' ) */ /*executor2 ) */, 2) AS d_self
	FROM vt WHERE id = _existing_id |
	SELECT id,
		ROUND(/*executor1 VECTOR_DISTANCE( */ /*executor2 VEC_DISTANCE_EUCLIDEAN( */
		v8 , v8
		/*executor1 , 'EUCLIDEAN' ) */ /*executor2 ) */, 2) AS d_self
	FROM vt WHERE id = _existing_id |
	SELECT id,
		ROUND(/*executor1 VECTOR_DISTANCE( */ /*executor2 VEC_DISTANCE_EUCLIDEAN( */
		v384 , v384
		/*executor1 , 'EUCLIDEAN' ) */ /*executor2 ) */, 2) AS d_self
	FROM vt WHERE id = _existing_id ;

# cosine(v,v) on a non-zero vector should be ~0 (zero-vector excluded — expected divergence)
select_self_distance_cosine:
	SELECT id,
		ROUND(/*executor1 VECTOR_DISTANCE( */ /*executor2 VEC_DISTANCE_COSINE( */
		v3 , v3
		/*executor1 , 'COSINE' ) */ /*executor2 ) */, 2) AS d_self
	FROM vt WHERE id = _existing_id |
	SELECT id,
		ROUND(/*executor1 VECTOR_DISTANCE( */ /*executor2 VEC_DISTANCE_COSINE( */
		v8 , v8
		/*executor1 , 'COSINE' ) */ /*executor2 ) */, 2) AS d_self
	FROM vt WHERE id = _existing_id ;

# dist(a,b) == dist(b,a) using stored columns (each _vector3 would re-roll independently)
select_commutativity:
	SELECT id,
		ROUND(/*executor1 VECTOR_DISTANCE( */ /*executor2 VEC_DISTANCE_EUCLIDEAN( */
		v4_baseline , v4_anomaly_a
		/*executor1 , 'EUCLIDEAN' ) */ /*executor2 ) */, 2) AS d_ab ,
		ROUND(/*executor1 VECTOR_DISTANCE( */ /*executor2 VEC_DISTANCE_EUCLIDEAN( */
		v4_anomaly_a , v4_baseline
		/*executor1 , 'EUCLIDEAN' ) */ /*executor2 ) */, 2) AS d_ba
	FROM vt WHERE id = _existing_id ;

select_commutativity_cosine:
	SELECT id,
		ROUND(/*executor1 VECTOR_DISTANCE( */ /*executor2 VEC_DISTANCE_COSINE( */
		v4_baseline , v4_anomaly_b
		/*executor1 , 'COSINE' ) */ /*executor2 ) */, 2) AS d_ab ,
		ROUND(/*executor1 VECTOR_DISTANCE( */ /*executor2 VEC_DISTANCE_COSINE( */
		v4_anomaly_b , v4_baseline
		/*executor1 , 'COSINE' ) */ /*executor2 ) */, 2) AS d_ba
	FROM vt WHERE id = _existing_id ;

# Stored column pairs (same width)
select_column_pair:
	SELECT id,
		ROUND(/*executor1 VECTOR_DISTANCE( */ /*executor2 VEC_DISTANCE_EUCLIDEAN( */
		v4_baseline , v4_anomaly_a
		/*executor1 , 'EUCLIDEAN' ) */ /*executor2 ) */, 2) AS d_euclid ,
		ROUND(/*executor1 VECTOR_DISTANCE( */ /*executor2 VEC_DISTANCE_COSINE( */
		v4_baseline , v4_anomaly_a
		/*executor1 , 'COSINE' ) */ /*executor2 ) */, 2) AS d_cosine
	FROM vt WHERE id = _existing_id |
	SELECT id,
		ROUND(/*executor1 VECTOR_DISTANCE( */ /*executor2 VEC_DISTANCE_EUCLIDEAN( */
		v4_baseline , v4_anomaly_b
		/*executor1 , 'EUCLIDEAN' ) */ /*executor2 ) */, 2) AS d_euclid ,
		ROUND(/*executor1 VECTOR_DISTANCE( */ /*executor2 VEC_DISTANCE_COSINE( */
		v4_baseline , v4_anomaly_b
		/*executor1 , 'COSINE' ) */ /*executor2 ) */, 2) AS d_cosine
	FROM vt WHERE id = _existing_id |
	SELECT id,
		ROUND(/*executor1 VECTOR_DISTANCE( */ /*executor2 VEC_DISTANCE_EUCLIDEAN( */
		v4_anomaly_a , v4_anomaly_b
		/*executor1 , 'EUCLIDEAN' ) */ /*executor2 ) */, 2) AS d_euclid ,
		ROUND(/*executor1 VECTOR_DISTANCE( */ /*executor2 VEC_DISTANCE_COSINE( */
		v4_anomaly_a , v4_anomaly_b
		/*executor1 , 'COSINE' ) */ /*executor2 ) */, 2) AS d_cosine
	FROM vt WHERE id = _existing_id ;

# Two random equal-width literals (both engines see identical SQL text)
select_literal_pair:
	SELECT
		ROUND(/*executor1 VECTOR_DISTANCE( */ /*executor2 VEC_DISTANCE_EUCLIDEAN( */
		/*executor1 STRING_TO_VECTOR */ /*executor2 VEC_FromText */(_vector3) ,
		/*executor1 STRING_TO_VECTOR */ /*executor2 VEC_FromText */(_vector3)
		/*executor1 , 'EUCLIDEAN' ) */ /*executor2 ) */, 2) AS d
	FROM vt LIMIT 1 |
	SELECT
		ROUND(/*executor1 VECTOR_DISTANCE( */ /*executor2 VEC_DISTANCE_COSINE( */
		/*executor1 STRING_TO_VECTOR */ /*executor2 VEC_FromText */(_vector8) ,
		/*executor1 STRING_TO_VECTOR */ /*executor2 VEC_FromText */(_vector8)
		/*executor1 , 'COSINE' ) */ /*executor2 ) */, 2) AS d
	FROM vt LIMIT 1 ;

# ---------------------------------------------------------------------------
# Anomaly scenarios (4d columns seeded in init_vectors_comp.sql)
# ---------------------------------------------------------------------------

select_anomaly_comparison:
	SELECT
		ROUND(/*executor1 VECTOR_DISTANCE( */ /*executor2 VEC_DISTANCE_COSINE( */
		v4_baseline , v4_anomaly_a
		/*executor1 , 'COSINE' ) */ /*executor2 ) */, 2) AS a_cosine ,
		ROUND(/*executor1 VECTOR_DISTANCE( */ /*executor2 VEC_DISTANCE_EUCLIDEAN( */
		v4_baseline , v4_anomaly_a
		/*executor1 , 'EUCLIDEAN' ) */ /*executor2 ) */, 2) AS a_euclidean ,
		ROUND(/*executor1 VECTOR_DISTANCE( */ /*executor2 VEC_DISTANCE_COSINE( */
		v4_baseline , v4_anomaly_b
		/*executor1 , 'COSINE' ) */ /*executor2 ) */, 2) AS b_cosine ,
		ROUND(/*executor1 VECTOR_DISTANCE( */ /*executor2 VEC_DISTANCE_EUCLIDEAN( */
		v4_baseline , v4_anomaly_b
		/*executor1 , 'EUCLIDEAN' ) */ /*executor2 ) */, 2) AS b_euclidean
	FROM vt WHERE id = _existing_id ;

# Note: each _v4_* token expands once per appearance, so a_cosine/a_euclidean
# intentionally share the same generated literal only within a single rule
# alternative that references the token once -- here each metric gets its own
# roll, which is fine for cross-engine equality of that specific expression.
select_anomaly_random_severity:
	SELECT
		ROUND(/*executor1 VECTOR_DISTANCE( */ /*executor2 VEC_DISTANCE_COSINE( */
		v4_baseline , /*executor1 STRING_TO_VECTOR */ /*executor2 VEC_FromText */(_v4_type_a_magnitude_drift)
		/*executor1 , 'COSINE' ) */ /*executor2 ) */, 2) AS a_cosine ,
		ROUND(/*executor1 VECTOR_DISTANCE( */ /*executor2 VEC_DISTANCE_EUCLIDEAN( */
		v4_baseline , /*executor1 STRING_TO_VECTOR */ /*executor2 VEC_FromText */(_v4_type_a_magnitude_drift)
		/*executor1 , 'EUCLIDEAN' ) */ /*executor2 ) */, 2) AS a_euclidean ,
		ROUND(/*executor1 VECTOR_DISTANCE( */ /*executor2 VEC_DISTANCE_COSINE( */
		v4_baseline , /*executor1 STRING_TO_VECTOR */ /*executor2 VEC_FromText */(_v4_type_b_directional_spike)
		/*executor1 , 'COSINE' ) */ /*executor2 ) */, 2) AS b_cosine ,
		ROUND(/*executor1 VECTOR_DISTANCE( */ /*executor2 VEC_DISTANCE_EUCLIDEAN( */
		v4_baseline , /*executor1 STRING_TO_VECTOR */ /*executor2 VEC_FromText */(_v4_type_b_directional_spike)
		/*executor1 , 'EUCLIDEAN' ) */ /*executor2 ) */, 2) AS b_euclidean
	FROM vt WHERE id = _existing_id ;

# ---------------------------------------------------------------------------
# Shared NULL / edge behavior (both should return NULL, not error)
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
		AS d ;

# float32 rounding: identical high-precision literals -> distance ~0.
# Uses ROUND(..., 6) (not the general-purpose ROUND(..., 2)) so a real
# float32-vs-MariaDB precision gap can surface; last-bit IEEE noise lives
# further out. Both args come from one perl block so the literal is identical
# (two separate _vector3_high_precision expansions would re-roll independently).
select_precision_truncation:
	SELECT
		ROUND(/*executor1 VECTOR_DISTANCE( */ /*executor2 VEC_DISTANCE_EUCLIDEAN( */
		_hp_identical_pair
		/*executor1 , 'EUCLIDEAN' ) */ /*executor2 ) */, 6) AS d
	FROM vt LIMIT 1 ;

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

# Type-A: magnitude drift (scale all components) -- cosine should stay ~0 vs baseline direction
_v4_type_a_magnitude_drift:
	{ my $s = 0.5 + rand() * 2.5; "'[" . join(',', map { sprintf('%.4f', $_ * $s) } (50,55,10,45)) . "]'" } ;

# Type-B: directional spike on one axis
_v4_type_b_directional_spike:
	{ my @v = (50,55,10,45); $v[int(rand(4))] += 20 + rand() * 80; "'[" . join(',', map { sprintf('%.4f', $_) } @v) . "]'" } ;

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

# Cosine distance is typically in [0, 2]; keep thresholds in that range
_threshold_cosine:
	0 | 0.1 | 0.5 | 1 | 1.5 | 2 ;
