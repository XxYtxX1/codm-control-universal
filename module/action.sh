#!/system/bin/sh
# Magisk "Action" button: open the WebUI in your browser
MODDIR=${0%/*}
. "$MODDIR/common.sh"
load_cfg
URL="http://127.0.0.1:$WEBUI_PORT/"
echo "Opening $URL"
am start --user 0 -a android.intent.action.VIEW -d "$URL" >/dev/null 2>&1 || echo "Open $URL in your browser"
