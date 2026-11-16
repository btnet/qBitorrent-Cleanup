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

# Internal Variables
MOVE_SECONDS=$((MOVE_DAYS_LIMIT * 86400))
PURGE_SECONDS=$((PURGE_DAYS_LIMIT * 86400))
CURRENT_TIME=$(date +%s)
COOKIE_FILE="/tmp/qbit_lifecycle_cookie.txt"

# Dependencies Check
if ! command -v jq &> /dev/null; then echo "Error: jq not found."; exit 1; fi

# Login (and save cookie to COOKIE_FILE)
curl -s -i --cookie-jar "$COOKIE_FILE" --header "Referer: $HOST" --data "username=$USERNAME&password=$PASSWORD" "$HOST/api/v2/auth/login" > /dev/null

echo "----------------------------------------------------------------------------------------------------"
printf "%-50s | %-12s | %-15s | %s\n" "Torrent Name" "Size" "Age (Days)" "Action"
echo "----------------------------------------------------------------------------------------------------"

# Fetch ALL torrents once so we can detect cross-seeds sharing the same content_path
ALL_TORRENTS=$(curl -s "$HOST/api/v2/torrents/info" --cookie "$COOKIE_FILE")

# Build JSON array of source categories for jq filtering
SRC_CATS_JSON=$(printf '%s\n' "${SOURCE_CATEGORIES[@]}" | jq -R . | jq -s .)

# --- PART 1: THE MOVER (Grouped by content_path to keep cross-seeds intact) ---
echo "$ALL_TORRENTS" | jq -c --argjson src_cats "$SRC_CATS_JSON" '
  group_by(.content_path)[] |
  # Keep only groups where at least one torrent is in our source categories
  select(any(.[]; .category as $c | $src_cats | index($c))) |
  {
    name: .[0].name,
    size: .[0].size,
    count: length,
    hashes: ([.[].hash] | join("|")),
    # Use max so it picks the newest completion_on timestamp in the group (waiting for youngest sibling)
    newest_completion: ([.[].completion_on] | max),
    all_completed: (all(.[]; .completion_on > 0)),
    max_upspeed: ([.[].upspeed] | max),
    max_last_activity: ([.[].last_activity] | max)
  }
' | while read -r group; do
    NAME=$(echo "$group" | jq -r '.name')
    BYTES=$(echo "$group" | jq -r '.size')
    COUNT=$(echo "$group" | jq -r '.count')
    HASHES=$(echo "$group" | jq -r '.hashes')
    NEWEST_COMPLETED=$(echo "$group" | jq -r '.newest_completion')
    ALL_COMPLETED=$(echo "$group" | jq -r '.all_completed')
    MAX_UPSPEED=$(echo "$group" | jq -r '.max_upspeed')
    MAX_LAST_ACTIVITY=$(echo "$group" | jq -r '.max_last_activity')

    SIZE=$(numfmt --to=iec-i --suffix=B "$BYTES" 2>/dev/null || echo "$BYTES B")

    DISPLAY_NAME="$NAME"
    if [ "$COUNT" -gt 1 ]; then
        DISPLAY_NAME="[x$COUNT] $NAME"
    fi

    if [ "$ALL_COMPLETED" = "true" ]; then
        AGE=$((CURRENT_TIME - NEWEST_COMPLETED))
        if [ "$AGE" -gt "$MOVE_SECONDS" ]; then
            DAYS_OLD=$((AGE / 86400))
            
            # Check if active now or within the last 24 hours (86400 seconds)
            IS_RECENTLY_ACTIVE=false
            if [ "$MAX_UPSPEED" -gt 0 ]; then
                IS_RECENTLY_ACTIVE=true
            elif [ "$MAX_LAST_ACTIVITY" -gt 0 ]; then
                TIME_SINCE_ACTIVITY=$((CURRENT_TIME - MAX_LAST_ACTIVITY))
                if [ "$TIME_SINCE_ACTIVITY" -le 86400 ]; then
                    IS_RECENTLY_ACTIVE=true
                fi
            fi

            if [ "$IS_RECENTLY_ACTIVE" = "true" ]; then
                printf "%-50.50s | %-12s | %-15s | %s\n" "$DISPLAY_NAME" "$SIZE" "$DAYS_OLD days" "SKIPPED (Active in last 24h)"
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
TORRENTS_DEL=$(curl -s "$HOST/api/v2/torrents/info?category=$DEST_CATEGORY" --cookie "$COOKIE_FILE")

echo "$TORRENTS_DEL" | jq -c '.[]' | while read -r torrent; do
    HASH=$(echo "$torrent" | jq -r '.hash')
    NAME=$(echo "$torrent" | jq -r '.name')
    BYTES=$(echo "$torrent" | jq -r '.size')
    COMPLETED_ON=$(echo "$torrent" | jq -r '.completion_on')
    UPSPEED=$(echo "$torrent" | jq -r '.upspeed')
    LAST_ACTIVITY=$(echo "$torrent" | jq -r '.last_activity')
    
    SIZE=$(numfmt --to=iec-i --suffix=B "$BYTES" 2>/dev/null || echo "$BYTES B")
    
    if [ "$COMPLETED_ON" -gt 0 ]; then
        AGE=$((CURRENT_TIME - COMPLETED_ON))
        if [ "$AGE" -gt "$PURGE_SECONDS" ]; then
            DAYS_OLD=$((AGE / 86400))
            
            # Check if active now or within the last 24 hours (86400 seconds)
            IS_RECENTLY_ACTIVE=false
            if [ "$UPSPEED" -gt 0 ]; then
                IS_RECENTLY_ACTIVE=true
            elif [ "$LAST_ACTIVITY" -gt 0 ]; then
                TIME_SINCE_ACTIVITY=$((CURRENT_TIME - LAST_ACTIVITY))
                if [ "$TIME_SINCE_ACTIVITY" -le 86400 ]; then
                    IS_RECENTLY_ACTIVE=true
                fi
            fi
            
            if [ "$IS_RECENTLY_ACTIVE" = "true" ]; then
                printf "%-50.50s | %-12s | %-15s | %s\n" "$NAME" "$SIZE" "$DAYS_OLD days" "SKIPPED (Active in last 24h)"
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

# Cleanup
curl -s -X POST "$HOST/api/v2/auth/logout" --cookie "$COOKIE_FILE" > /dev/null 2>&1
rm -f "$COOKIE_FILE"
echo "----------------------------------------------------------------------------------------------------"
echo "Job Completed At: $(date)"
