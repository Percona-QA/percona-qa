DROP TABLE IF EXISTS vector_test;

CREATE TABLE vector_test (
    id INT AUTO_INCREMENT PRIMARY KEY,
    v3 VECTOR(3),
    v4 VECTOR(4),
    v16 VECTOR(16),
    metric_name VARCHAR(30)
);

INSERT INTO vector_test (v3, v4, v16, metric_name) VALUES
-- Standard vectors for basic distance calculations
(TO_VECTOR('[0.1, 0.2, 0.3]'), TO_VECTOR('[1.0, 2.0, 3.0, 4.0]'), TO_VECTOR('[0.1, 0.2, 0.3, 0.4, 0.5, 0.6, 0.7, 0.8, 0.9, 1.0, 1.1, 1.2, 1.3, 1.4, 1.5, 1.6]'), 'EUCLIDEAN'),
(TO_VECTOR('[0.4, 0.5, 0.6]'), TO_VECTOR('[4.0, 3.0, 2.0, 1.0]'), TO_VECTOR('[1.6, 1.5, 1.4, 1.3, 1.2, 1.1, 1.0, 0.9, 0.8, 0.7, 0.6, 0.5, 0.4, 0.3, 0.2, 0.1]'), 'COSINE'),

-- Zero vectors
(TO_VECTOR('[0.0, 0.0, 0.0]'), TO_VECTOR('[0.0, 0.0, 0.0, 0.0]'), TO_VECTOR('[0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0]'), 'DOT'),

-- Extreme values (FLT_MAX edges)
(TO_VECTOR('[3.4028234E38, 3.4028234E38, 3.4028234E38]'), TO_VECTOR('[3.4028234E38, 3.4028234E38, 3.4028234E38, 3.4028234E38]'), NULL, 'MANHATTAN'),
(TO_VECTOR('[-3.4028234E38, -3.4028234E38, -3.4028234E38]'), TO_VECTOR('[-3.4028234E38, -3.4028234E38, -3.4028234E38, -3.4028234E38]'), NULL, 'EUCLIDEAN_SQUARED'),

-- NULL vectors
(NULL, TO_VECTOR('[1.1, 2.2, 3.3, 4.4]'), NULL, 'EUCLIDEAN'),
(TO_VECTOR('[1.1, 2.2, 3.3]'), NULL, TO_VECTOR('[1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14, 15, 16]'), 'COSINE'),

-- Negatives and Integers (implicit float casting)
(TO_VECTOR('[-1.0, -2.5, 3.1]'), TO_VECTOR('[-1, -2, -3, -4]'), TO_VECTOR('[-0.1, -0.2, -0.3, -0.4, -0.5, -0.6, -0.7, -0.8, -0.9, -1.0, -1.1, -1.2, -1.3, -1.4, -1.5, -1.6]'), 'DOT');

