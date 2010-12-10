query:
	# lineitem -> orders -> customer /* -> nation -> region */
	SELECT COUNT(*) FROM lineitem LEFT JOIN orders ON ( lineitem.l_orderkey = orders.o_orderkey ) LEFT JOIN customer ON ( orders.o_orderkey = customer.c_custkey ) WHERE where_lineitem_orders_customer |

	# orders -> customer /* -> nation -> region */	
	SELECT COUNT(*) FROM orders LEFT JOIN customer ON ( orders.o_custkey = customer.c_custkey ) WHERE where_orders_customer ;

	# lineitem -> part
	SELECT COUNT(*) FROM lineitem LEFT JOIN part ON ( lineitem.l_partkey = part.p_partkey ) WHERE where_lineitem_part |
	
	# lineitem -> partsupp -> part
	SELECT COUNT(*) FROM lineitem LEFT JOIN partsupp ON ( lineitem.l_partkey = partsupp.ps_partkey ) LEFT JOIN part ON ( partsupp.ps_partkey = part.p_partkey ) WHERE where_lineitem_partsupp_part |

	# partsupp -> part 
	SELECT COUNT(*) FROM partsupp LEFT JOIN part ON ( partsupp.ps_partkey = part.p_partkey ) WHERE where_partupp_part |

	# partsupp -> supplier /* -> nation -> region */
	SELECT COUNT(*) FROM partsupp LEFT JOIN supplier ON (partsupp.ps_suppkey = supplier.s_suppkey ) where_partsupp_supplider ;

where_lineitem_orders_customer:
	lineitem_orders_customer_cond and_or lineitem_orders_customer_cond | lineitem_orders_customer_cond and_or where_lineitem_orders_customer ;

lineitem_orders_customer_cond:
	lineitem_cond | orders_cond | customer_cond ;

where_orders_customer:
	orders_customer_cond and_or orders_customer_cond | orders_customer_cond and_or where_orders_customer ;

orders_customer_cond:
	orders_cond | customer_cond ;

where_lineitem_part:
	lineitem_part_cond and_or lineitem_part_cond | lineitem_part_cond and_or where_lineitem_part;

lineitem_part_cond:
	lineitem_cond | part_cond;

where_lineitem_partsupp_part:
	lineitem_partsupp_part_cond and_or lineitem_partsupp_part_cond | lineitem_partsupp_part_cond and_or where_lineitem_partsupp_part;

lineitem_partsupp_part_cond:
	lineitem_cond | partsupp_cond | part_cond ;

where_partsupp_part:
	partsupp_part_cond and_or partsupp_part_cond | partsupp_part_cond and_or where_partsupp_part;

partsupp_part_cond:
	partsupp_cond | part_cond ;

where_partsupp_supplier:
	partsupp_supplier_cond and_or partsupp_supplier_cond | partsupp_supplier_cond and_or where_partsupp_supplier;

partsupp_supplier_cond:
	partsupp_cond | supplier_cond ;

partsupp_cond:
	partsupp.ps_partkey comp_op _digit |
	partsupp.ps_suppkey comp_op _digit ;

lineitem_cond:
	lineitem.l_orderkey comp_op _digit |
	lineitem.l_partkey comp_op _digit ;

orders_cond:
	orders.o_orderkey comp_op _digit |
	orders.o_custkey comp_op _digit ;

customer_cond:
	customer.c_custkey comp_op _digit ;

part_cond:
	part.p_partkey comp_op _digit ;

supplier_cond:
	supplier.s_suppkey comp_op _digit ;

comp_op:
	= | > | < | >= | <= | <> | != ;

and_or:
	AND | OR ;


