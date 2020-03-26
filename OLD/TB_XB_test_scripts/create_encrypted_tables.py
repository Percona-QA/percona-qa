import mysql.connector

cnx = mysql.connector.connect(user='root', password='',
                              host='127.0.0.1',
                              database='dbtest2',
                              port=22100)
cursor = cnx.cursor()

create_stmt = "create table sbtest%s like dbtest.sbtest1"
insert_stmt = "insert into sbtest%s select * from dbtest.sbtest1 where id < 100"
alter_stmt = "alter table sbtest%s encryption='Y'"

for i in range(10000):
	cursor.execute(create_stmt % i)
	print "created table sbtest%s" % i
	cursor.execute(insert_stmt % i)
	print "Inserted into table sbtest%s" % i
	cursor.execute(alter_stmt % i)
	print "Ecnryption altered table sbtest%s" %i


cursor.close()
cnx.close()
