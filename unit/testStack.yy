query: 
        { $stack->push(); $stack->set("arg","LEFT"); } SELECT * from join { $stack->pop(undef) } |
        { $stack->push(); $stack->set("arg","RIGHT"); } SELECT * from join { $stack->pop(undef) } ;

join:
       { $stack->push() }      
       table_or_join 
       { $stack->set("left",$stack->get("result")); }
       { $stack->get("arg") } JOIN table_or_join 
       ON 
       { my $left = $stack->get("left"); my %s=map{$_=>1} @$left; my @r=(keys %s); $prng->arrayElement(\@r).".col = " }
       { my $right = $stack->get("result"); my %s=map{$_=>1} @$right; my @r=(keys %s); $prng->arrayElement(\@r).".col" }
       { my $left = $stack->get("left");  my $right = $stack->get("result"); my @n = (); push(@n,@$right); push(@n,@$left); $stack->pop(\@n); return undef } ;

table_or_join:
        table | table | join ;

table:
       { $stack->push(); my $x = "t".$prng->digit();  my @s=($x); $stack->pop(\@s); $x } ;
