#!/system/bin/sh
# Thin HTTP wrapper around api.sh for busybox httpd (127.0.0.1 only).
MODDIR="${CODM_MODDIR:-/data/adb/modules/codm_ultra_stretch}"
deny() { printf 'Status: %s\r\nContent-Type: text/plain\r\nCache-Control: no-store\r\n\r\n%s\n' "$1" "$2"; exit 0; }

case "$HTTP_HOST" in ""|127.0.0.1:*|localhost:*) ;; *) deny "403 Forbidden" "bad host";; esac

BODY=""
case "$QUERY_STRING" in
  cmd=state|cmd=log|cmd=live|cmd=diag)
    [ "$REQUEST_METHOD" = "GET" ] || deny "405 Method Not Allowed" "GET only";;
  cmd=save|cmd=test|cmd=restore|cmd=locktest|cmd=ovltest)
    [ "$REQUEST_METHOD" = "POST" ] || deny "405 Method Not Allowed" "POST only"
    case "$CONTENT_TYPE" in application/x-codm-stretch*) ;; *) deny "415 Unsupported Media Type" "bad content type";; esac
    N=${CONTENT_LENGTH:-0}
    case "$N" in *[!0-9]*|"") N=0;; esac
    [ "$N" -gt 4096 ] && deny "413 Payload Too Large" "too big"
    [ "$N" -gt 0 ] && BODY=$(head -c "$N" 2>/dev/null);;
  *) deny "400 Bad Request" "bad request";;
esac

CMD=${QUERY_STRING#cmd=}
case "$CMD" in log|diag) CT="text/plain";; *) CT="application/json";; esac
printf 'Content-Type: %s; charset=utf-8\r\nCache-Control: no-store\r\n\r\n' "$CT"
exec sh "$MODDIR/api.sh" "$CMD" "$BODY"
