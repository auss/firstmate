import sys
cmd = sys.argv[1]
if cmd == "poll":
    print("poll: scanned=1 evaluated=1 ready=1")
elif cmd == "ready":
    print("{\"schema_version\":1,\"delivery_id\":\"fmp:live-42:hash:readiness-v1\",\"issue\":{\"id\":\"live-42\",\"title\":\"Live wake evidence\"},\"evaluation\":{\"score\":1}}")
elif cmd == "receipt":
    print("receipt recorded for " + sys.argv[2])
else:
    raise SystemExit(1)
