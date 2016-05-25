import mysql.connector

cnx = mysql.connector.connect(user='root', password='Baku12345#',
                              host='127.0.0.1',
                              database='dbtest')
cursor = cnx.cursor()

alter_stmt = "alter table sbtest1 add index(`k`)"

for i in range(1000):
	cursor.execute(alter_stmt)
	print "Added index %s", i




cursor.close()
cnx.close()
