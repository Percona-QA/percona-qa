#
# Very simple grammar, nice for detecting easy bugs that we have otherwise
# missed (especially with bigger tables).
#

query:
	INSERT INTO _table VALUES ( _bit );
