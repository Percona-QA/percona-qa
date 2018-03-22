-- Created by Alexey Kopytov, Percona LLC

queries = {}

function thread_init(thread_id)
   local file = io.open(pquery-file, "r")
   local i = 1
   for line in file:lines() do
      queries[i] = line
      i = i + 1
   end
end

function event(thread_id)
   db_query(queries[sb_rand_uniform(1, #queries)])
end
