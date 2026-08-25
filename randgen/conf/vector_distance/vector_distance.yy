# vector_distance.yy
# Extended RQG grammar for Percona Server VECTOR_DISTANCE / DISTANCE (PS-11167) fuzz testing.
# Incorporates precision boundaries, case/hex variations, anomaly types, and synonym validation.

# vector_distance.yy

query:
	select_valid | select_valid | select_valid | select_valid |
	select_ranking | select_ranking | select_ranking |
	select_synonym_pair | select_synonym_errors |
	select_error_arity |
	select_error_type |
	select_error_metric |
	select_error_dimension |
	select_error_bytelen |
	select_null_propagation |
	select_zero_vector_cosine |
	select_metadata_check |
	select_aggregate |
	select_where_threshold |
	select_precision_truncation_check |
	select_dot_product_ordering |
	select_anomaly_comparison |
	select_anomaly_random_severity ;

# ---------------------------------------------------------------------------
# Valid-path queries & Synonym Equivalence (F-1, F-3, F-7, F-8, F-10, F-11, 7.1)
# ---------------------------------------------------------------------------

# _vector_pair_same_width expands once to "arg1 , arg2" at a single width so
# valid-path weighting stays on successful distance calculations (not dim-mismatch).
select_valid:
	SELECT id, VECTOR_DISTANCE( _vector_pair_same_width , _metric_valid ) AS d FROM vt WHERE id = _existing_id ;

select_ranking:
	SELECT id, label, category, VECTOR_DISTANCE( v3 , STRING_TO_VECTOR(_vector3) , _metric_valid ) AS d FROM vt ORDER BY d _asc_desc LIMIT _small_limit ;

# One Perl expansion builds both synonym columns with the same args + metric.
select_synonym_pair:
	SELECT _synonym_equiv_exprs FROM vt WHERE id = _existing_id ;

select_aggregate:
	SELECT category, AVG( VECTOR_DISTANCE( v3 , STRING_TO_VECTOR(_vector3) , _metric_valid ) ) AS avg_d FROM vt GROUP BY category ;

select_where_threshold:
	SELECT id FROM vt WHERE VECTOR_DISTANCE( v3 , STRING_TO_VECTOR(_vector3) , _metric_valid ) < _threshold ;

select_metadata_check:
	DROP TEMPORARY TABLE IF EXISTS tmp_dist_meta ;
	CREATE TEMPORARY TABLE IF NOT EXISTS tmp_dist_meta AS 
		SELECT VECTOR_DISTANCE( _vector_pair_same_width , _metric_valid ) AS d 
		FROM vt WHERE id = _existing_id ;

# ---------------------------------------------------------------------------
# Phase 3 Real-World Scenarios: Magnitude Drift vs Directional Anomalies (Section 4)
# ---------------------------------------------------------------------------

select_anomaly_comparison:
	SELECT 
		VECTOR_DISTANCE(v4_baseline, v4_anomaly_a, 'COSINE') AS a_cosine,
		VECTOR_DISTANCE(v4_baseline, v4_anomaly_a, 'EUCLIDEAN') AS a_euclidean,
		VECTOR_DISTANCE(v4_baseline, v4_anomaly_b, 'COSINE') AS b_cosine,
		VECTOR_DISTANCE(v4_baseline, v4_anomaly_b, 'EUCLIDEAN') AS b_euclidean
	FROM vt WHERE id = _existing_id ;

select_dot_product_ordering:
	SELECT id, VECTOR_DISTANCE(v4_baseline, _vector_source_4d, 'DOT') AS dot_dist FROM vt ORDER BY dot_dist ASC LIMIT _small_limit ;

# Randomized-severity version of select_anomaly_comparison: instead of only
# comparing against the two FIXED anomaly rows baked into init_vectors.sql,
# this generates a fresh magnitude-drift or directional-spike vector on every
# invocation, at a random severity. This extends Section 4's core finding
# (Cosine blind to proportional-magnitude drift regardless of severity) to a
# continuous range of severities rather than the handful of fixed multipliers
# present in the static test data.
select_anomaly_random_severity:
	SELECT
		VECTOR_DISTANCE(v4_baseline, STRING_TO_VECTOR(_v4_type_a_magnitude_drift), 'COSINE')    AS a_cosine,
		VECTOR_DISTANCE(v4_baseline, STRING_TO_VECTOR(_v4_type_a_magnitude_drift), 'EUCLIDEAN')  AS a_euclidean,
		VECTOR_DISTANCE(v4_baseline, STRING_TO_VECTOR(_v4_type_b_directional_spike), 'COSINE')   AS b_cosine,
		VECTOR_DISTANCE(v4_baseline, STRING_TO_VECTOR(_v4_type_b_directional_spike), 'EUCLIDEAN') AS b_euclidean
	FROM vt WHERE id = _existing_id ;

# ---------------------------------------------------------------------------
# Phase 4 Scenario: float32 Precision & Rounding Verification (Section 5)
# ---------------------------------------------------------------------------

select_precision_truncation_check:
	SELECT VECTOR_DISTANCE( STRING_TO_VECTOR(_vector3_high_precision) , STRING_TO_VECTOR(_vector3_high_precision) , 'EUCLIDEAN' ) FROM vt LIMIT 1 ;

# ---------------------------------------------------------------------------
# Error-path queries (F-1, F-2, F-3, F-5, F-6)
# ---------------------------------------------------------------------------

# F-1: wrong arity -> ER_WRONG_PARAMCOUNT_TO_NATIVE_FCT
select_error_arity:
	SELECT VECTOR_DISTANCE( _vector_source , _vector_source ) FROM vt WHERE id = _existing_id |
	SELECT VECTOR_DISTANCE( _vector_source , _vector_source , _metric_valid , _metric_valid ) FROM vt WHERE id = _existing_id |
	SELECT DISTANCE( _vector_source , _vector_source ) FROM vt WHERE id = _existing_id ;

select_synonym_errors:
	SELECT DISTANCE( _vector_source, _vector_source, 'HAMMING' ) FROM vt WHERE id = _existing_id |
	SELECT DISTANCE( _vector_source, _vector_source ) FROM vt WHERE id = _existing_id ;

# F-2: wrong argument type -> ER_WRONG_ARGUMENTS
select_error_type:
	SELECT VECTOR_DISTANCE( _digit , _digit , _metric_valid ) |
	SELECT VECTOR_DISTANCE( 'not_a_vector_literal' , v3 , _metric_valid ) FROM vt WHERE id = _existing_id ;

# F-3: metric argument must be a constant literal from the accepted set
select_error_metric:
	SELECT VECTOR_DISTANCE( _vector_source , _vector_source , _metric_invalid ) FROM vt WHERE id = _existing_id |
	SELECT VECTOR_DISTANCE( _vector_source , _vector_source , NULL ) FROM vt WHERE id = _existing_id |
	SELECT VECTOR_DISTANCE( _vector_source , _vector_source , CONCAT(_metric_prefix, _metric_suffix) ) FROM vt WHERE id = _existing_id |
	SELECT VECTOR_DISTANCE( _vector_source , _vector_source , category ) FROM vt WHERE id = _existing_id ;

# F-5: dimension mismatch -> ER_WRONG_ARGUMENTS
select_error_dimension:
	SELECT VECTOR_DISTANCE( v3 , v8 , _metric_valid ) FROM vt WHERE id = _existing_id |
	SELECT VECTOR_DISTANCE( v3 , v384 , _metric_valid ) FROM vt WHERE id = _existing_id |
	SELECT VECTOR_DISTANCE( STRING_TO_VECTOR(_vector3) , STRING_TO_VECTOR(_vector8) , _metric_valid ) ;

# F-6: byte length not a multiple of 4 -> ER_TO_VECTOR_CONVERSION
select_error_bytelen:
	SELECT VECTOR_DISTANCE( _bad_byte_literal , STRING_TO_VECTOR(_vector3) , _metric_valid ) |
	SELECT VECTOR_TO_STRING( _bad_byte_literal ) ;

# F-4 & 7.3: Symmetric NULL vector argument propagation 
select_null_propagation:
	SELECT VECTOR_DISTANCE( NULL , v3 , _metric_valid ) FROM vt WHERE id = _existing_id |
	SELECT VECTOR_DISTANCE( v3 , NULL , _metric_valid ) FROM vt WHERE id = _existing_id |
	SELECT VECTOR_DISTANCE( NULL , NULL , _metric_valid ) ;

# F-9: Cosine on a zero-norm vector -> NULL, warning clause check
select_zero_vector_cosine:
	SELECT VECTOR_DISTANCE( STRING_TO_VECTOR('[0,0,0]') , v3 , 'COSINE' ) FROM vt WHERE id = _existing_id ;

# ---------------------------------------------------------------------------
# Token / terminal rules
# ---------------------------------------------------------------------------

_vector_source:
	v3 | v8 | v384 | STRING_TO_VECTOR(_vector3) | STRING_TO_VECTOR(_vector8) | STRING_TO_VECTOR(_vector384) ;

# Equal-width argument pairs only. Used by valid-path / metadata rules.
_vector_pair_same_width:
	v3 , v3 |
	v3 , STRING_TO_VECTOR(_vector3) |
	STRING_TO_VECTOR(_vector3) , v3 |
	STRING_TO_VECTOR(_vector3) , STRING_TO_VECTOR(_vector3) |
	v8 , v8 |
	v8 , STRING_TO_VECTOR(_vector8) |
	STRING_TO_VECTOR(_vector8) , v8 |
	STRING_TO_VECTOR(_vector8) , STRING_TO_VECTOR(_vector8) |
	v384 , v384 |
	v384 , STRING_TO_VECTOR(_vector384) |
	STRING_TO_VECTOR(_vector384) , v384 |
	STRING_TO_VECTOR(_vector384) , STRING_TO_VECTOR(_vector384) ;

# Keep on one line: a ';' inside a multi-line { } block ends the grammar rule.
# Emits: DISTANCE(a,b,m) AS via_distance , VECTOR_DISTANCE(a,b,m) AS via_vector_distance
_synonym_equiv_exprs:
	{ my @pairs; push @pairs, ['v3','v3'], ['v8','v8'], ['v384','v384']; my $l3 = "'[" . join(',', map { sprintf('%.4f', (rand() * 200) - 100) } (1..3)) . "]'"; my $l8 = "'[" . join(',', map { sprintf('%.4f', (rand() * 200) - 100) } (1..8)) . "]'"; my $l384 = "'[" . join(',', map { sprintf('%.6f', (rand() * 2) - 1) } (1..384)) . "]'"; push @pairs, ['v3',"STRING_TO_VECTOR($l3)"], ["STRING_TO_VECTOR($l3)",'v3'], ["STRING_TO_VECTOR($l3)","STRING_TO_VECTOR($l3)"], ['v8',"STRING_TO_VECTOR($l8)"], ["STRING_TO_VECTOR($l8)",'v8'], ["STRING_TO_VECTOR($l8)","STRING_TO_VECTOR($l8)"], ['v384',"STRING_TO_VECTOR($l384)"], ["STRING_TO_VECTOR($l384)",'v384'], ["STRING_TO_VECTOR($l384)","STRING_TO_VECTOR($l384)"]; my ($a,$b) = @{$pairs[int(rand(@pairs))]}; my @m = ("'EUCLIDEAN'","'euclidean'","'EuClIdEaN'","'EUCLIDEAN_SQUARED'","'euclidean_squared'","'EuClIdEaN_sQuArEd'","'COSINE'","'cosine'","X'434F53494E45'","'DOT'","'dot'","X'444F54'","'MANHATTAN'","'manhattan'"); my $m = $m[int(rand(@m))]; "DISTANCE( $a , $b , $m ) AS via_distance , VECTOR_DISTANCE( $a , $b , $m ) AS via_vector_distance" } ;

_vector_source_4d:
	v4_baseline | v4_anomaly_a | v4_anomaly_b ;

# Extended to include variations in Casing and Hex representations as per spec (F-3)
_metric_valid:
	'EUCLIDEAN' | 'euclidean' | 'EuClIdEaN' | 
	'EUCLIDEAN_SQUARED' | 'euclidean_squared' | 'EuClIdEaN_sQuArEd' |
	'COSINE' | 'cosine' | X'434F53494E45' | 
	'DOT' | 'dot' | X'444F54' | 
	'MANHATTAN' | 'manhattan' ;

_metric_invalid:
	'HAMMING' | 'JACCARD' | 'NOSUCHMETRIC' | '' | 'euclidian' ;

_metric_prefix:
	'COS' | 'EUC' | 'MAN' ;

_metric_suffix:
	'INE' | 'LIDEAN' | 'HATTAN' ;

_bad_byte_literal:
	0x0102030405 | 0x010203 | 0x0102030405060708090A | 0x01 ;

# Base Standard Vector Generators
_vector3:
	{ "'[" . join(',', map { sprintf('%.4f', (rand() * 200) - 100) } (1..3)) . "]'" } ;

_vector8:
	{ "'[" . join(',', map { sprintf('%.4f', (rand() * 200) - 100) } (1..8)) . "]'" } ;

_vector384:
	{ "'[" . join(',', map { sprintf('%.6f', (rand() * 2) - 1) } (1..384)) . "]'" } ;

# Phase 4: High-precision values to challenge IEEE-754 round-to-nearest boundary limits
_vector3_high_precision:
	{ "'[" . join(',', map { sprintf('%.15f', rand()) } (1..3)) . "]'" } ;

# Phase 3 Scenario Vectors: Industrial Sensor Drift Simulation
_v4_type_a_magnitude_drift:
	{ my $scale = (1.3, 1.6, 2.0)[int(rand(3))]; "'[" . join(',', map { sprintf('%.4f', $_ * $scale) } (50, 55, 10, 45)) . "]'" } ;

_v4_type_b_directional_spike:
	{ my $vibration_spike = 10 + (rand() * 90); "'[50.0000,55.0000," . sprintf('%.4f', $vibration_spike) . ",45.0000]'" } ;

_category:
	'fruit' | 'vehicles' | 'weather' | 'technology' ;

_existing_id:
	1 | 2 | 3 | 4 | 5 | 10 | 20 | 50 ;

_small_limit:
	1 | 3 | 5 | 10 ;

_asc_desc:
	ASC | DESC ;

_threshold:
	0 | 1 | 5 | 10 | 50 | 100 ;
