SET GLOBAL innodb_limit_optimistic_insert_debug=2;
CREATE TABLE t1 (c TEXT, UNIQUE(c(2))) ENGINE=InnoDB;
ALTER TABLE t1 ADD c2 TINYBLOB NOT NULL FIRST;
INSERT INTO t1 VALUES (1,'x'),(1,'d'),(1,'r'),(1,'f'),(1,'y'),(1,'u'),(1,'m'),(1,'b'),(1,'o'),(1,'w'),(1,'m'),(1,'q'),(1,'a'),(1,'d'),(1,'g'),(1,'x'),(1,'f'),(1,'p'),(1,'j'),(1,'c');

SET GLOBAL innodb_limit_optimistic_insert_debug=2;
CREATE TABLE t1 (c VARCHAR(30) CHARACTER SET utf8, t TEXT CHARACTER SET utf8, UNIQUE (c (2)), UNIQUE (t (3))) ENGINE=InnoDB;
ALTER TABLE t1 ADD c2 TINYBLOB NOT NULL FIRST;
INSERT INTO t1 VALUES  (9,'w','w'), (2,'m','m'), (4,'q','q'), (0,NULL,NULL), (4,'d','d'), (8,'g','g'), (NULL,'x','x'), (NULL,'f','f'), (0,'p','p'), (NULL,'j','j'), (8,'c','c');

SET GLOBAL innodb_limit_optimistic_insert_debug=2;
CREATE TABLE t1 (c VARCHAR(30) CHARACTER SET utf8, t TEXT CHARACTER SET utf8, UNIQUE (c (2)), UNIQUE (t (3)));
ALTER TABLE t1 ADD c2 TINYBLOB NOT NULL FIRST;
INSERT INTO t1 VALUES (8,'x','x'), (7,'d','d'), (1,'r','r'), (7,'f','f'), (9,'y','y'), (NULL,'u','u'), (1,'m','m'), (9,NULL,NULL), (2,'o','o'), (9,'w','w'), (2,'m','m'), (4,'q','q'), (0,NULL,NULL), (4,'d','d'), (8,'g','g'), (NULL,'x','x'), (NULL,'f','f'), (0,'p','p'), (NULL,'j','j'), (8,'c','c');
