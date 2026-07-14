#!/bin/bash
# Start Flutter web test server — รันค้างได้แม้ปิด terminal
# Usage:
#   ./start_test_server.sh         → start server
#   ./start_test_server.sh stop    → stop server
#   ./start_test_server.sh status  → check status
#   ./start_test_server.sh build   → rebuild + restart

set -e
cd "$(dirname "$0")"

PORT=8080
LOGFILE="/tmp/flutter-web-server.log"
PIDFILE="/tmp/flutter-web-server.pid"

# Firebase + TURN config มาจาก .env (gitignored) — ไม่ commit secret ในสคริปต์
# ต้องมีไฟล์ .env (copy จาก .env.example แล้วเติมค่า) ใน telemedicine_app/
if [ ! -f .env ]; then
  echo "❌ ไม่พบ .env — copy .env.example → .env แล้วเติมค่า Firebase/TURN"
  exit 1
fi

cmd="${1:-start}"

case "$cmd" in
  build)
    echo "🔨 Building Flutter web..."
    flutter build web --release --dart-define-from-file=.env
    echo "🔧 Cache-busting flutter_bootstrap.js + main.dart.js..."
    VERSION="$(date +%s)"
    # 1. ใน index.html: <script src="flutter_bootstrap.js"> → ?v=TIMESTAMP
    sed -i.bak -E "s|flutter_bootstrap\\.js|flutter_bootstrap.js?v=${VERSION}|g" build/web/index.html
    # 2. ใน flutter_bootstrap.js: "main.dart.js" → "main.dart.js?v=TIMESTAMP"
    sed -i.bak -E "s|\"main\\.dart\\.js\"|\"main.dart.js?v=${VERSION}\"|g" build/web/flutter_bootstrap.js
    rm -f build/web/index.html.bak build/web/flutter_bootstrap.js.bak
    echo "✅ Build done (version=${VERSION}). Restarting server..."
    "$0" stop || true
    "$0" start
    ;;

  stop)
    if [ -f "$PIDFILE" ]; then
      pid=$(cat "$PIDFILE")
      if kill "$pid" 2>/dev/null; then
        echo "🛑 Stopped server (PID $pid)"
      fi
      rm -f "$PIDFILE"
    fi
    pkill -f "python3 -m http.server $PORT" 2>/dev/null || true
    ;;

  status)
    if [ -f "$PIDFILE" ] && kill -0 "$(cat "$PIDFILE")" 2>/dev/null; then
      echo "🟢 Running (PID $(cat "$PIDFILE")) — http://localhost:$PORT"
    else
      echo "⚪ Not running"
    fi
    ;;

  start)
    "$0" stop >/dev/null 2>&1 || true
    sleep 1
    cd build/web
    nohup python3 -m http.server "$PORT" > "$LOGFILE" 2>&1 &
    echo $! > "$PIDFILE"
    sleep 1
    echo "🟢 Server started — http://localhost:$PORT"
    echo "    PID: $(cat "$PIDFILE")"
    echo "    Log: $LOGFILE"
    ;;

  *)
    echo "Usage: $0 {start|stop|status|build}"
    exit 1
    ;;
esac
