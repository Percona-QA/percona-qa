query:
        SELECT distance_func FROM vector_test LIMIT _digit ;
      | SELECT id , distance_func AS d FROM vector_test ORDER BY d LIMIT _digit ;
      | CREATE TABLE t_vec AS SELECT distance_func AS dist ;

distance_func:
        DISTANCE ( vector_expr , vector_expr , valid_metric )
      | VECTOR_DISTANCE ( vector_expr , vector_expr , valid_metric )
      | DISTANCE ( vector_expr , vector_expr , invalid_metric )
      | VECTOR_DISTANCE ( vector_expr , vector_expr , non_constant_metric )
      | DISTANCE ( vector_expr , vector_expr , valid_metric , extra_arg )
      | DISTANCE ( vector_expr , valid_metric ) ;

vector_col:
        v3 
      | v4 
      | v16 ;

vector_expr:
        vector_col
      | TO_VECTOR ( 'vector_string' )
      | binary_string
      | NULL
      | invalid_type ;

valid_metric:
        'EUCLIDEAN'
      | 'EUCLIDEAN_SQUARED'
      | 'COSINE'
      | 'DOT'
      | 'MANHATTAN'
      | 'euclidean'
      | 'CoSiNe'
      | X'4555434C494445414E' ;

invalid_metric:
        'NOSUCHMETRIC'
      | 'HAMMING'
      | NULL
      | '' ;

non_constant_metric:
        CONCAT ( 'CO' , 'SINE' )
      | metric_name ;

vector_string:
        [0.1, 0.2, 0.3]
      | [1.5, 2.5, 3.5, 4.5]
      | [0.0, 0.0, 0.0]
      | [3.4028235E38, 3.4028235E38, 3.4028235E38]
      | [0.1, 0.2, 0.3, 0.4, 0.5, 0.6, 0.7, 0.8, 0.9, 1.0, 1.1, 1.2, 1.3, 1.4, 1.5, 1.6, 1.7] ;

binary_string:
        UNHEX ( '3D0AD7A3703D0AD7A370' )
      | SUBSTRING ( UNHEX ( '003D0AD7A3703D0AD7A370' ) , digit ) ;

invalid_type:
        digit
      | 'not_a_vector'
      | NOW() ;

extra_arg:
        digit
      | 'extra' ;

