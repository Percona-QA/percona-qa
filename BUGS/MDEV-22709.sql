SET SESSION session_track_user_variables=1;
SET @inserted_value=REPEAT(1,16777180);  # Only crashes when >=16777180 (max = 16777216)
