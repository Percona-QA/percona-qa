import mysql.connector

cnx = mysql.connector.connect(user='root', password='Baku12345#',
                              host='127.0.0.1',
                              database='dbtest2')
cursor = cnx.cursor()

create_stmt = "CREATE TABLE sbtest%s ( \
  `id` int(10) unsigned NOT NULL AUTO_INCREMENT, \
  `k` int(10) unsigned NOT NULL DEFAULT '0', \
  `c` char(120) NOT NULL DEFAULT '', \
  `pad` char(60) NOT NULL DEFAULT '', \
  PRIMARY KEY (`id`), \
  KEY `k_1` (`k`) \
) ENGINE=InnoDB encryption='Y'"

insert_stmt = "insert into sbtest%s select * from dbtest.sbtest1 where id < 100"
#alter_stmt = "alter table sbtest%s encryption='Y'"

for i in range(10000):
	cursor.execute(create_stmt % i)
	print "created table sbtest%s" % i
	cursor.execute(insert_stmt % i)
	print "Inserted into table sbtest%s" % i
	#cursor.execute(alter_stmt % i)
	#print "Ecnryption altered table sbtest%s" %i


cursor.close()
cnx.close()
