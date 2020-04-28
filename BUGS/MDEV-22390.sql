SET @@SESSION.tmp_table_size=1048576;
SET @@SESSION.max_sort_length=5;
SET @@SESSION.sort_buffer_size=1024;
SET @@SESSION.max_length_for_sort_data=66556;
SELECT * FROM information_schema.session_variables ORDER BY variable_name;
