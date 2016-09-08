sed -i "s|.*SET.*completion_type.*RELEASE.*|SELECT * FROM t2;|" *.sql      # RELEASES connection as soon as any transaction is complete
sed -i "s|.*SET.*completion_type.*2.*|SELECT * FROM t2;|" *.sql            # RELEASES connection as soon as any transaction is complete
sed -i "s|.*[^O] RELEASE;|SELECT * FROM t1;|" *.sql                        # RELEASE releases connection as soon as this stransaction is complete. Regex avoids NO RELEASE
sed -i "s|.*AND RELEASE.*|SELECT * FROM t1;|" *.sql                        # RELEASE releases connection as soon as this stransaction is complete. Regex avoids NO RELEASE
sed -i "s|KILL CONNECTION @id;|SELECT * FROM t1;|" *.sql                   # Kills connection, potentially with current connection ID, no real SQL value either
sed -i "s|KILL.*CONNECTION_ID().*|SELECT * FROM t1;|" *.sql                # Kills connection, potentially with current connection ID, no real SQL value either
