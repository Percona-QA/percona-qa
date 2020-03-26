import mysql.connector

cnx = mysql.connector.connect(user='root', password='',
                              host='127.0.0.1',
                              database='dbtest',
			      port=22000)
cursor = cnx.cursor()

#alter_index = "alter table sbtest1 add index(`k`)"
drop_index = "alter table sbtest1 drop index k_{}"


for i in range(6,1000):
	#cursor.execute(alter_index)
	#print "Added index %s", i
        drop_index = drop_index.format(i)
        cursor.execute(drop_index)
        print "Dropped index"
	




cursor.close()
cnx.close()
