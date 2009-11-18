query: 
        { @nonaggregates = () ; $tables = 0 ; $fields = 0 ; "" }
        { $stack->push() } SELECT distinct straight_join select_option select_list from join { $stack->pop(undef) } ;

distinct: DISTINCT | | | |  ;

select_option:  | | | | | | | | | SQL_SMALL_RESULT ;

straight_join:  | | | | | | | | | | | STRAIGHT_JOIN ;

select_list:
	new_select_item |
	new_select_item , select_list |
        new_select_item , select_list ;

new_select_item:
	nonaggregate_select_item;

nonaggregate_select_item:
        table_alias . int_field_name AS { my $f = "field".++$fields ; push @nonaggregates , $f ; $f } ;

table_alias:
  t1 | t1 | t1 | t1 | t1 |
  t2 | t2 | t2 | t3 | t3 |
  t4 | t5  ;
	
join:
       { $stack->push() }      
       table_or_join 
       { $stack->set("left",$stack->get("result")); }
       LEFT JOIN table_or_join 
       ON 
       { my $left = $stack->get("left"); my %s=map{$_=>1} @$left; my @r=(keys %s); $prng->arrayElement(\@r).".col = " }
       { my $right = $stack->get("result"); my %s=map{$_=>1} @$right; my @r=(keys %s); $prng->arrayElement(\@r).".col" }
       { my $left = $stack->get("left");  my $right = $stack->get("result"); my @n = (); push(@n,@$right); push(@n,@$left); $stack->pop(\@n); return undef } ;

table_or_join:
        table | table | table | join | join ;

table:
       { $stack->push(); my $x = "t".$prng->digit();  my @s=($x); $stack->pop(\@s); $x } ;

int_field_name:
  `pk` | `int_key` | `int` ;

