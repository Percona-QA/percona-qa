import mysql.connector

cnx = mysql.connector.connect(user='root', password='',
                              host='127.0.0.1',
                              database='dbtest2',
                              port=22100)
cursor = cnx.cursor()

create_stmt = "create table sbtest%s like dbtest.sbtest1"
insert_stmt = "insert into sbtest%s select * from dbtest.sbtest1 where id < 100"
alter_enc = "alter table sbtest%s encryption='Y'"
alter_comp = "alter table sbtest%s compression='lz4'"
alter_tblspc = "alter table sbtest%s tablespace=t1"

for i in range(10000):
	cursor.execute(create_stmt % i)
	print "created table sbtest%s" % i
	cursor.execute(insert_stmt % i)
	print "Inserted into table sbtest%s" % i
	cursor.execute(alter_enc % i)
	print "Encryption altered table sbtest%s" %i
	cursor.execute(alter_comp %i)
	print "Table sbtest%s compressed" % i
        cursor.execute(alter_tblspc % i)
	print "Tablespace altered to sbtest%" % i


cursor.close()
cnx.close()
