CHANGE MASTER TO MASTER_HOST='h', MASTER_USER='u';
SET @@GLOBAL.session_track_system_variables=NULL;
START SLAVE IO_THREAD;

SET @@GLOBAL.session_track_system_variables=NULL;
SET @@SESSION.session_track_system_variables=default;
SELECT 1;

SET @@global.session_track_system_variables=NULL;
INSERT DELAYED INTO t VALUES(0);
