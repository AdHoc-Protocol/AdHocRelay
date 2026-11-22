#!/bin/sh
# Every case of docs/vectors.tsv a server makes or checks - kid, bind, seen, bound, knock, read, answer - through both scripts of the server,
# adhoc-relay-server.pl and .ps1, `--vector` / `-Vector`: the bytes each makes are those of the file. A write is of the relay alone.
#
#   sh .github/vectors.sh        ( from the folder of AdHocRelay; perl and pwsh )
cd "$(dirname "$0")/.." || exit 1
tab=$(printf '\t')
cr=$(printf '\r')
failed=0
cases=0
while IFS="$tab" read -r what of want relay; do
	want=${want%"$cr"} # a checkout of Windows ends its lines in CRLF
	case "$what" in kid | bind | seen | bound | knock | read | answer) ;; *) continue ;; esac
	cases=$((cases + 1))
	got=$(perl Server/adhoc-relay-server.pl --vector "$what $of")
	[ "$got" = "$want" ] || { echo "FAIL  .pl  '$what $of': '$got', not '$want'"; failed=$((failed + 1)); }
	got=$(pwsh -NoProfile -File Server/adhoc-relay-server.ps1 -Vector "$what $of" | tr -d '\r')
	[ "$got" = "$want" ] || { echo "FAIL  .ps1 '$what $of': '$got', not '$want'"; failed=$((failed + 1)); }
done < docs/vectors.tsv
echo "$cases cases, $failed failed"
[ "$failed" -eq 0 ]
