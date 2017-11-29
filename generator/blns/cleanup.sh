grep -vE --binary-files=text "^[ \t]*$|^[ \t]*#|^Scu|^Pen|^Lig|^Jim|^Hor|^shi|^Rom|^htt|^Cra|^Lin|^Dr\.v|^mag|^Sup|^med|^eva|^moc|^exp|^Ars|^cla|^Tys|^Dic|^bas" blns.txt > blns2.txt
#sed -i "s/\[/\\\[/;s/|/\\\|/g" blns2.txt
sed -i "s/|/_/g;s|\\\|_|g;" blns2.txt
sed -i "s/^/'/;s/$/'/" blns2.txt
