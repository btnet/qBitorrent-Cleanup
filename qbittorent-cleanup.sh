#!/bin/bash

# --- Configuration ---
HOST="http://ip:port"
USERNAME="usernamehere"
PASSWORD="passwordhere"

# 1. MOVER SETTINGS (NVMe -> Array)
SOURCE_CATEGORIES=("cat1" "cat2" "etc")
DEST_CATEGORY="seeding"
MOVE_DAYS_LIMIT=1

# 2. JANITOR SETTINGS (Final Purge)
PURGE_DAYS_LIMIT=15

# 3. RECENT ACTIVITY THRESHOLD (Last 24 hours)
# Ignore torrents active in the last 24h ONLY if they transferred at least this many MB
MIN_ACTIVE_MB_24H=512

# Internal Variables
MOVE_SECONDS=$((MOVE_DAYS_LIMIT * 86400))
PURGE_SECONDS=$((PURGE_DAYS_LIMIT * 86400))
ACTIVE_WINDOW_SECONDS=86400
MIN_ACTIVE_BYTES_24H=$((MIN_ACTIVE_MB_24H * 1024 * 1024))
CURRENT_TIME=$(date +%s)
COOKIE_FILE="/tmp/qbit_lifecycle_cookie.txt"
STATE_FILE="/tmp/qbit_lifecycle_24h_state.json"

# Dependencies Check
if ! command -v jq &> /dev/null; then echo "Error: jq not found."; exit 1; fi

# Login (and save cookie to COOKIE_FILE)
curl -s -i --cookie-jar "$COOKIE_FILE" --header "Referer: $HOST" --data "username=$USERNAME&password=$PASSWORD" "$HOST/api/v2/auth/login" > /dev/null

echo "----------------------------------------------------------------------------------------------------"
printf "%-50s | %-12s | %-15s | %s\n" "Torrent Name" "Size" "Age (Days)" "Action"
echo "----------------------------------------------------------------------------------------------------"

# Fetch ALL torrents once so we can detect cross-seeds sharing the same content_path
ALL_TORRENTS=$(curl -s "$HOST/api/v2/torrents/info" --cookie "$COOKIE_FILE")

# Load previous state if present; prune snapshots older than 24h + 1h buffer
if [ -f "$STATE_FILE" ]; then
    PREV_STATE=$(jq --argjson now "$CURRENT_TIME" --argjson max_age 90000 '
        with_entries(select(($now - .value.ts) <= $max_age))
    ' "$STATE_FILE" 2>/dev/null || echo "{}")
else
    PREV_STATE="{}"
fi

# Helper function: returns 0 if torrent/group should be ignored due to 24h MB transfer
is_ignored_by_24h_mb() {
    local hash="$1"
    local upspeed="$2"
    local last_activity="$3"
    local uploaded_total="$4"
    local uploaded_session="$5"

    local recently_active=false
    if [ "$upspeed" -gt 0 ]; then
        recently_active=true
    elif [ "$last_activity" -gt 0 ]; then
        local since_act=$((CURRENT_TIME - last_activity))
        if [ "$since_act" -le "$ACTIVE_WINDOW_SECONDS" ]; then
            recently_active=true
        fi
    fi

    if [ "$recently_active" = false ]; then
        return 1
    fi

    # Calculate bytes transferred in the last 24h using saved snapshot if available
    local prev_uploaded
    prev_uploaded=$(echo "$PREV_STATE" | jq -r --arg h "$hash" '.[$h].uploaded // empty')

    local delta_bytes=0
    if [ -n "$prev_uploaded" ] && [ "$prev_uploaded" -ge 0 ]; then
        delta_bytes=$((uploaded_total - prev_uploaded))
        if [ "$delta_bytes" -lt 0 ]; then
            delta_bytes="$uploaded_session"
        fi
    else
        # First run without a 24h snapshot: fall back to current session upload
        delta_bytes="$uploaded_session"
    fi

    if [ "$delta_bytes" -ge "$MIN_ACTIVE_BYTES_24H" ]; then
        return 0
    fi

    return 1
}

# Build JSON array of source categories for jq filtering
SRC_CATS_JSON=$(printf '%s\n' "${SOURCE_CATEGORIES[@]}" | jq -R . | jq -s .)

# --- PART 1: THE MOVER (Grouped by content_path to keep cross-seeds intact) ---
echo "$ALL_TORRENTS" | jq -c --argjson src_cats "$SRC_CATS_JSON" '
  group_by(.content_path)[] |
  select(any(.[]; .category as $c | $src_cats | index($c))) |
  {
    name: .[0].name,
    size: .[0].size,
    count: length,
    hashes: ([.[].hash] | join("|")),
    primary_hash: .[0].hash,
    newest_completion: ([.[].completion_on] | max),
    all_completed: (all(.[]; .completion_on > 0)),
    max_upspeed: ([.[].upspeed] | max),
    max_last_activity: ([.[].last_activity] | max),
    total_uploaded: ([.[].uploaded] | add // 0),
    total_session_uploaded: ([.[].uploaded_session] | add // 0)
  }
' | while read -r group; do
    NAME=$(echo "$group" | jq -r '.name')
    BYTES=$(echo "$group" | jq -r '.size')
    COUNT=$(echo "$group" | jq -r '.count')
    HASHES=$(echo "$group" | jq -r '.hashes')
    PRIMARY_HASH=$(echo "$group" | jq -r '.primary_hash')
    NEWEST_COMPLETED=$(echo "$group" | jq -r '.newest_completion')
    ALL_COMPLETED=$(echo "$group" | jq -r '.all_completed')
    MAX_UPSPEED=$(echo "$group" | jq -r '.max_upspeed')
    MAX_LAST_ACTIVITY=$(echo "$group" | jq -r '.max_last_activity')
    TOTAL_UPLOADED=$(echo "$group" | jq -r '.total_uploaded')
    TOTAL_SESSION_UPLOADED=$(echo "$group" | jq -r '.total_session_uploaded')

    SIZE=$(numfmt --to=iec-i --suffix=B "$BYTES" 2>/dev/null || echo "$BYTES B")

    DISPLAY_NAME="$NAME"
    if [ "$COUNT" -gt 1 ]; then
        DISPLAY_NAME="[x$COUNT] $NAME"
    fi

    if [ "$ALL_COMPLETED" = "true" ]; then
        AGE=$((CURRENT_TIME - NEWEST_COMPLETED))
        if [ "$AGE" -gt "$MOVE_SECONDS" ]; then
            DAYS_OLD=$((AGE / 86400))

            # For cross-seed groups, sum previous uploaded bytes across all hashes in the group
            GROUP_PREV_UPLOADED=0
            IFS='|' read -ra HASH_ARR <<< "$HASHES"
            HAS_SNAPSHOT=true
            for h in "${HASH_ARR[@]}"; do
                h_prev=$(echo "$PREV_STATE" | jq -r --arg key "$h" '.[$key].uploaded // empty')
                if [ -z "$h_prev" ]; then
                    HAS_SNAPSHOT=false
                    break
                fi
                GROUP_PREV_UPLOADED=$((GROUP_PREV_UPLOADED + h_prev))
            done

            RECENTLY_ACTIVE=false
            if [ "$MAX_UPSPEED" -gt 0 ]; then
                RECENTLY_ACTIVE=true
            elif [ "$MAX_LAST_ACTIVITY" -gt 0 ] && [ $((CURRENT_TIME - MAX_LAST_ACTIVITY)) -le "$ACTIVE_WINDOW_SECONDS" ]; then
                RECENTLY_ACTIVE=true
            fi

            IGNORE_MOVE=false
            if [ "$RECENTLY_ACTIVE" = true ]; then
                if [ "$HAS_SNAPSHOT" = true ]; then
                    DELTA_BYTES=$((TOTAL_UPLOADED - GROUP_PREV_UPLOADED))
                    [ "$DELTA_BYTES" -lt 0 ] && DELTA_BYTES="$TOTAL_SESSION_UPLOADED"
                else
                    DELTA_BYTES="$TOTAL_SESSION_UPLOADED"
                fi

                if [ "$DELTA_BYTES" -ge "$MIN_ACTIVE_BYTES_24H" ]; then
                    IGNORE_MOVE=true
                fi
            fi

            if [ "$IGNORE_MOVE" = true ]; then
                DELTA_MB=$((DELTA_BYTES / 1024 / 1024))
                printf "%-50.50s | %-12s | %-15s | %s\n" "$DISPLAY_NAME" "$SIZE" "$DAYS_OLD days" "SKIPPED (${DELTA_MB}MB in 24h)"
            else
                printf "%-50.50s | %-12s | %-15s | %s\n" "$DISPLAY_NAME" "$SIZE" "$DAYS_OLD days" "MOVING TO $DEST_CATEGORY"
                
                curl -s -X POST "$HOST/api/v2/torrents/setCategory" \
                     --cookie "$COOKIE_FILE" \
                     --data-urlencode "hashes=$HASHES" \
                     --data-urlencode "category=$DEST_CATEGORY"
            fi
        fi
    fi
done

# --- PART 2: THE JANITOR ---
TORRENTS_DEL=$(echo "$ALL_TORRENTS" | jq -c --arg cat "$DEST_CATEGORY" '[.[] | select(.category == $cat)]')

echo "$TORRENTS_DEL" | jq -c '.[]' | while read -r torrent; do
    HASH=$(echo "$torrent" | jq -r '.hash')
    NAME=$(echo "$torrent" | jq -r '.name')
    BYTES=$(echo "$torrent" | jq -r '.size')
    COMPLETED_ON=$(echo "$torrent" | jq -r '.completion_on')
    UPSPEED=$(echo "$torrent" | jq -r '.upspeed')
    LAST_ACTIVITY=$(echo "$torrent" | jq -r '.last_activity')
    UPLOADED=$(echo "$torrent" | jq -r '.uploaded')
    UPLOADED_SESSION=$(echo "$torrent" | jq -r '.uploaded_session')
    
    SIZE=$(numfmt --to=iec-i --suffix=B "$BYTES" 2>/dev/null || echo "$BYTES B")
    
    if [ "$COMPLETED_ON" -gt 0 ]; then
        AGE=$((CURRENT_TIME - COMPLETED_ON))
        if [ "$AGE" -gt "$PURGE_SECONDS" ]; then
            DAYS_OLD=$((AGE / 86400))

            if is_ignored_by_24h_mb "$HASH" "$UPSPEED" "$LAST_ACTIVITY" "$UPLOADED" "$UPLOADED_SESSION"; then
                PREV_UP=$(echo "$PREV_STATE" | jq -r --arg h "$HASH" '.[$h].uploaded // empty')
                if [ -n "$PREV_UP" ]; then
                    DELTA_B=$((UPLOADED - PREV_UP))
                    [ "$DELTA_B" -lt 0 ] && DELTA_B="$UPLOADED_SESSION"
                else
                    DELTA_B="$UPLOADED_SESSION"
                fi
                DELTA_MB=$((DELTA_B / 1024 / 1024))
                printf "%-50.50s | %-12s | %-15s | %s\n" "$NAME" "$SIZE" "$DAYS_OLD days" "SKIPPED (${DELTA_MB}MB in 24h)"
            else
                printf "%-50.50s | %-12s | %-15s | %s\n" "$NAME" "$SIZE" "$DAYS_OLD days" "PURGING DATA"
                
                curl -s -X POST "$HOST/api/v2/torrents/delete" \
                     --cookie "$COOKIE_FILE" \
                     --data-urlencode "hashes=$HASH" \
                     --data "deleteFiles=true"
            fi
        fi
    fi
done

# Save updated state snapshot (preserving entries <24h old so rolling 24h comparison works accurately)
echo "$ALL_TORRENTS" | jq -c --argjson now "$CURRENT_TIME" --argjson prev "$PREV_STATE" '
  reduce .[] as $t (
    $prev;
    if ($prev[$t.hash] == null) or (($now - ($prev[$t.hash].ts // 0)) >= 86400) then
      .[$t.hash] = { uploaded: $t.uploaded, ts: $now }
    else
      .
    end
  )
' > "$STATE_FILE"

# Cleanup
curl -s -X POST "$HOST/api/v2/auth/logout" --cookie "$COOKIE_FILE" > /dev/null 2>&1
rm -f "$COOKIE_FILE"
echo "----------------------------------------------------------------------------------------------------"
echo "Job Completed At: $(date)"
