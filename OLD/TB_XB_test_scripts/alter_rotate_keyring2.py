import mysql.connector

cnx = mysql.connector.connect(user='root', password='',
                              host='127.0.0.1',
                              database='dbtest',
			      port=22000)
cursor = cnx.cursor()

alter_stmt = "ALTER INSTANCE ROTATE INNODB MASTER KEY"

while(True):
	print "Master key rotated"
	cursor.execute(alter_stmt)



cursor.close()
cnx.close()
