import sys
if sys.argv[1] == "poll":
    print("Linear API unavailable for live errror scenario", file=sys.stderr)
    raise SystemExit(7)
if sys.argv[1] == "ready":
    raise SystemExit(0)
raise SystemExit(1)
