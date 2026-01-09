#!/bin/bash
# =====================================
# WordPress Contributor Bulk Removal Script
# Removes contributors and their comments
# =====================================

# Color definitions
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
MAGENTA='\033[0;35m'
CYAN='\033[0;36m'
WHITE='\033[1;37m'
GRAY='\033[0;90m'
NC='\033[0m'

BASE_DIR="/var/www/domains"
LOG_DIR="$HOME/wp-cleanup-logs"
TIMESTAMP=$(date +%Y%m%d_%H%M%S)
MAX_DELETE=20000
BATCH_SIZE=500  # Process deletions in batches to avoid query size limits

# Create log directory
mkdir -p "$LOG_DIR"
LOG_FILE="$LOG_DIR/contributor_deletion_$TIMESTAMP.log"

# =====================================
# Functions
# =====================================

log_message() {
    echo "$1" | tee -a "$LOG_FILE"
}

log_only() {
    echo "$1" >> "$LOG_FILE"
}

print_header() {
    echo -e "${CYAN}=============================================${NC}"
    echo -e "${CYAN}==== WordPress Contributor Removal =========${NC}"
    echo -e "${CYAN}==== Max: $MAX_DELETE users per run ========${NC}"
    echo -e "${CYAN}==== Batch size: $BATCH_SIZE ===============${NC}"
    echo -e "${CYAN}=============================================${NC}"
    echo
}

extract_db_config() {
    local site_path=$1
    local config_file="$site_path/wp-config.php"
    
    DB_NAME=$(grep "DB_NAME" "$config_file" | cut -d"'" -f4)
    DB_USER=$(grep "DB_USER" "$config_file" | cut -d"'" -f4)
    DB_PASS=$(grep "DB_PASSWORD" "$config_file" | cut -d"'" -f4)
    DB_HOST=$(grep "DB_HOST" "$config_file" | cut -d"'" -f4)
    PREFIX=$(grep "\$table_prefix" "$config_file" | cut -d"'" -f2)
    
    # Default prefix if not found
    [ -z "$PREFIX" ] && PREFIX="wp_"
    
    # Validate required fields
    if [ -z "$DB_NAME" ] || [ -z "$DB_USER" ]; then
        return 1
    fi
    
    return 0
}

get_contributors() {
    local limit=$1
    
    mysql -h "$DB_HOST" -u "$DB_USER" -p"$DB_PASS" "$DB_NAME" -sN -e "
        SELECT DISTINCT u.ID, u.user_login, u.user_email
        FROM ${PREFIX}users u
        INNER JOIN ${PREFIX}usermeta um ON u.ID = um.user_id
        WHERE um.meta_key = '${PREFIX}capabilities'
        AND um.meta_value LIKE '%contributor%'
        LIMIT $limit;
    " 2>/dev/null
}

count_comments() {
    local user_ids=$1
    
    mysql -h "$DB_HOST" -u "$DB_USER" -p"$DB_PASS" "$DB_NAME" -sN -e "
        SELECT COUNT(*) FROM ${PREFIX}comments WHERE user_id IN ($user_ids);
    " 2>/dev/null
}

delete_contributor_batch() {
    local user_ids=$1
    
    # Delete usermeta
    mysql -h "$DB_HOST" -u "$DB_USER" -p"$DB_PASS" "$DB_NAME" -e "
        DELETE FROM ${PREFIX}usermeta WHERE user_id IN ($user_ids);
    " 2>/dev/null
    
    if [ $? -ne 0 ]; then
        return 1
    fi
    
    # Delete users
    mysql -h "$DB_HOST" -u "$DB_USER" -p"$DB_PASS" "$DB_NAME" -e "
        DELETE FROM ${PREFIX}users WHERE ID IN ($user_ids);
    " 2>/dev/null
    
    if [ $? -ne 0 ]; then
        return 1
    fi
    
    return 0
}

delete_comments_batch() {
    local user_ids=$1
    
    # Delete commentmeta
    mysql -h "$DB_HOST" -u "$DB_USER" -p"$DB_PASS" "$DB_NAME" -e "
        DELETE cm FROM ${PREFIX}commentmeta cm
        INNER JOIN ${PREFIX}comments c ON cm.comment_id = c.comment_ID
        WHERE c.user_id IN ($user_ids);
    " 2>/dev/null
    
    if [ $? -ne 0 ]; then
        return 1
    fi
    
    # Delete comments
    mysql -h "$DB_HOST" -u "$DB_USER" -p"$DB_PASS" "$DB_NAME" -e "
        DELETE FROM ${PREFIX}comments WHERE user_id IN ($user_ids);
    " 2>/dev/null
    
    if [ $? -ne 0 ]; then
        return 1
    fi
    
    return 0
}

delete_contributor_data() {
    local all_user_ids=("$@")
    local total_users=${#all_user_ids[@]}
    local deleted_users=0
    local deleted_comments=0
    
    echo -e "${BLUE}Processing $total_users users in batches of $BATCH_SIZE...${NC}"
    
    # Process in batches
    for ((i=0; i<$total_users; i+=$BATCH_SIZE)); do
        local end=$((i + BATCH_SIZE))
        [ $end -gt $total_users ] && end=$total_users
        
        local batch_size=$((end - i))
        local batch_num=$((i / BATCH_SIZE + 1))
        local total_batches=$(((total_users + BATCH_SIZE - 1) / BATCH_SIZE))
        
        echo -e "${GRAY}  Batch $batch_num/$total_batches ($batch_size users)...${NC}"
        
        # Get user IDs for this batch
        local batch_ids=""
        for ((j=i; j<end; j++)); do
            if [ -z "$batch_ids" ]; then
                batch_ids="${all_user_ids[$j]}"
            else
                batch_ids="$batch_ids,${all_user_ids[$j]}"
            fi
        done
        
        # Count comments for this batch
        local comment_count=$(mysql -h "$DB_HOST" -u "$DB_USER" -p"$DB_PASS" "$DB_NAME" -sN -e "
            SELECT COUNT(*) FROM ${PREFIX}comments WHERE user_id IN ($batch_ids);
        " 2>/dev/null)
        comment_count=${comment_count:-0}
        
        # Delete comments if any exist
        if [ "$comment_count" -gt 0 ]; then
            if ! delete_comments_batch "$batch_ids"; then
                echo -e "${RED}  Error deleting comments for batch $batch_num${NC}"
                log_only "Error deleting comments for batch $batch_num"
                return 1
            fi
            deleted_comments=$((deleted_comments + comment_count))
        fi
        
        # Delete users and their meta
        if ! delete_contributor_batch "$batch_ids"; then
            echo -e "${RED}  Error deleting users for batch $batch_num${NC}"
            log_only "Error deleting users for batch $batch_num"
            return 1
        fi
        
        deleted_users=$((deleted_users + batch_size))
        echo -e "${GRAY}    ✓ Deleted $batch_size users$([ $comment_count -gt 0 ] && echo ", $comment_count comments")${NC}"
    done
    
    # Return success and set global counters
    BATCH_DELETED_USERS=$deleted_users
    BATCH_DELETED_COMMENTS=$deleted_comments
    return 0
}

# =====================================
# Main Script
# =====================================

print_header

# Mode selection
echo -e "${YELLOW}Select mode:${NC}"
echo -e "${WHITE}  1) Normal mode (delete contributors)${NC}"
echo -e "${WHITE}  2) Diagnostic mode (check only, no deletion)${NC}"
read -p "$(echo -e ${YELLOW}Enter choice [1-2]: ${NC})" MODE_CHOICE

if [[ ! "$MODE_CHOICE" =~ ^[1-2]$ ]]; then
    echo -e "${RED}Invalid choice. Exiting.${NC}"
    exit 1
fi

DIAGNOSTIC_MODE=false
[ "$MODE_CHOICE" == "2" ] && DIAGNOSTIC_MODE=true

if [ "$DIAGNOSTIC_MODE" = true ]; then
    echo -e "${BLUE}Running in DIAGNOSTIC mode - no deletions will occur${NC}"
else
    echo
    echo -e "${YELLOW}This script will remove up to $MAX_DELETE users with the 'contributor' role.${NC}"
    echo -e "${YELLOW}Their comments will also be permanently deleted.${NC}"
    echo
    read -p "$(echo -e ${RED}Are you sure? Type 'yes' to proceed: ${NC})" CONFIRM
    
    if [ "$CONFIRM" != "yes" ]; then
        echo -e "${RED}Aborted by user.${NC}"
        exit 1
    fi
fi

echo
echo -e "${BLUE}Searching WordPress sites under $BASE_DIR ...${NC}"
echo -e "${GRAY}Log file: $LOG_FILE${NC}"
echo

# Initialize log
{
    echo "=== WordPress Contributor Deletion Log ==="
    echo "Timestamp: $(date)"
    echo "Mode: $([ "$DIAGNOSTIC_MODE" = true ] && echo "DIAGNOSTIC" || echo "NORMAL")"
    echo "Maximum deletions per run: $MAX_DELETE"
    echo "Batch size: $BATCH_SIZE"
    echo "========================================"
    echo
} > "$LOG_FILE"

TOTAL_DELETED_USERS=0
TOTAL_DELETED_COMMENTS=0
REMAINING_TO_DELETE=$MAX_DELETE
SITES_PROCESSED=0

# Process each WordPress site
for SITE_PATH in $BASE_DIR/*/public_html; do
    # Check deletion limit
    if [ $REMAINING_TO_DELETE -le 0 ]; then
        echo -e "${YELLOW}Reached maximum deletion limit of $MAX_DELETE users. Stopping.${NC}"
        log_only "Reached maximum deletion limit"
        break
    fi
    
    # Check if WordPress exists
    if [ ! -f "$SITE_PATH/wp-config.php" ]; then
        continue
    fi
    
    echo -e "${MAGENTA}-------------------------------------------${NC}"
    echo -e "${WHITE}Site: ${CYAN}$SITE_PATH${NC}"
    log_only "Site: $SITE_PATH"
    
    # Extract database configuration
    if ! extract_db_config "$SITE_PATH"; then
        echo -e "${RED}Error: Could not extract database credentials${NC}"
        log_only "Error: Could not extract database credentials"
        echo
        continue
    fi
    
    echo -e "${GRAY}Database: $DB_NAME, Prefix: $PREFIX${NC}"
    log_only "Database: $DB_NAME, Prefix: $PREFIX"
    
    # Get contributors
    echo -e "${GRAY}Searching for contributors...${NC}"
    CONTRIBUTOR_DATA=$(get_contributors $REMAINING_TO_DELETE)
    
    if [ -z "$CONTRIBUTOR_DATA" ]; then
        echo -e "${GRAY}No contributors found${NC}"
        log_only "No contributors found"
        echo
        continue
    fi
    
    CONTRIBUTOR_COUNT=$(echo "$CONTRIBUTOR_DATA" | wc -l)
    echo -e "${GREEN}Found $CONTRIBUTOR_COUNT contributor(s)${NC}"
    log_only "Found $CONTRIBUTOR_COUNT contributor(s)"
    
    # Show preview
    echo -e "${YELLOW}Preview (first 10):${NC}"
    echo "$CONTRIBUTOR_DATA" | head -10 | while IFS=$'\t' read -r USER_ID USER_LOGIN USER_EMAIL; do
        echo -e "${GRAY}  - ID: $USER_ID, Login: $USER_LOGIN, Email: $USER_EMAIL${NC}"
        log_only "  User ID: $USER_ID, Login: $USER_LOGIN, Email: $USER_EMAIL"
    done
    
    [ "$CONTRIBUTOR_COUNT" -gt 10 ] && echo -e "${GRAY}  ... and $((CONTRIBUTOR_COUNT - 10)) more${NC}"
    
    # Get user IDs as array
    mapfile -t USER_ID_ARRAY < <(echo "$CONTRIBUTOR_DATA" | cut -f1)
    
    # Count total comments
    USER_IDS=$(echo "$CONTRIBUTOR_DATA" | cut -f1 | tr '\n' ',' | sed 's/,$//')
    COMMENT_COUNT=$(count_comments "$USER_IDS")
    COMMENT_COUNT=${COMMENT_COUNT:-0}
    
    if [ "$COMMENT_COUNT" -gt 0 ]; then
        echo -e "${YELLOW}These contributors have $COMMENT_COUNT comment(s)${NC}"
        log_only "Comments: $COMMENT_COUNT"
    else
        echo -e "${GRAY}No comments from these contributors${NC}"
        log_only "Comments: 0"
    fi
    
    # Perform deletion or skip in diagnostic mode
    if [ "$DIAGNOSTIC_MODE" = true ]; then
        echo -e "${BLUE}[DIAGNOSTIC] Would delete $CONTRIBUTOR_COUNT users and $COMMENT_COUNT comments${NC}"
        log_only "[DIAGNOSTIC] Would delete $CONTRIBUTOR_COUNT users and $COMMENT_COUNT comments"
    else
        if delete_contributor_data "${USER_ID_ARRAY[@]}"; then
            echo -e "${GREEN}✓ Deleted $BATCH_DELETED_USERS contributor(s)${NC}"
            log_only "✓ Deleted $BATCH_DELETED_USERS contributor(s)"
            
            if [ "$BATCH_DELETED_COMMENTS" -gt 0 ]; then
                echo -e "${GREEN}✓ Deleted $BATCH_DELETED_COMMENTS comment(s)${NC}"
                log_only "✓ Deleted $BATCH_DELETED_COMMENTS comment(s)"
            fi
            
            TOTAL_DELETED_USERS=$((TOTAL_DELETED_USERS + BATCH_DELETED_USERS))
            TOTAL_DELETED_COMMENTS=$((TOTAL_DELETED_COMMENTS + BATCH_DELETED_COMMENTS))
            REMAINING_TO_DELETE=$((REMAINING_TO_DELETE - BATCH_DELETED_USERS))
            
            echo -e "${CYAN}Remaining quota: $REMAINING_TO_DELETE users${NC}"
        else
            echo -e "${RED}✗ Deletion failed${NC}"
            log_only "✗ Deletion failed"
        fi
    fi
    
    SITES_PROCESSED=$((SITES_PROCESSED + 1))
    echo
done

# =====================================
# Final Summary
# =====================================

{
    echo "========================================"
    echo "Final Summary:"
    echo "Sites processed: $SITES_PROCESSED"
    echo "Contributors deleted: $TOTAL_DELETED_USERS"
    echo "Comments deleted: $TOTAL_DELETED_COMMENTS"
    echo "========================================"
} >> "$LOG_FILE"

echo -e "${CYAN}=============================================${NC}"
echo -e "${CYAN}==== Summary ===============================${NC}"
echo -e "${CYAN}=============================================${NC}"
echo

if [ "$DIAGNOSTIC_MODE" = true ]; then
    echo -e "${BLUE}Diagnostic mode - no deletions performed${NC}"
    echo -e "${BLUE}Sites scanned: $SITES_PROCESSED${NC}"
elif [ "$TOTAL_DELETED_USERS" -gt 0 ]; then
    echo -e "${GREEN}Contributors deleted: $TOTAL_DELETED_USERS${NC}"
    echo -e "${GREEN}Comments deleted: $TOTAL_DELETED_COMMENTS${NC}"
    echo -e "${GREEN}Sites processed: $SITES_PROCESSED${NC}"
    echo -e "${GREEN}Remaining quota: $REMAINING_TO_DELETE${NC}"
    echo
    
    [ $REMAINING_TO_DELETE -eq 0 ] && echo -e "${YELLOW}Run again to delete more contributors${NC}"
else
    echo -e "${YELLOW}No contributors were deleted${NC}"
fi

echo
echo -e "${CYAN}Log file: $LOG_FILE${NC}"
echo -e "${GRAY}Completed: $(date)${NC}"
