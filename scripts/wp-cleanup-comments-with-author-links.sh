#!/bin/bash
# =====================================
# WordPress Author URL Comment Deletion
# Deletes ALL comments from authors with URLs in their info
# Searches for http/https in: author name, email, URL
# =====================================

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
GRAY='\033[0;90m'
NC='\033[0m'

BASE_DIR="/var/www/domains"
TIMESTAMP=$(date +%Y%m%d_%H%M%S)
LOG_DIR="$HOME/wp-cleanup-logs"
LOG_FILE="$LOG_DIR/author_url_deletion_$TIMESTAMP.log"
BATCH_SIZE=100

mkdir -p "$LOG_DIR"

log_message() {
    echo "$1" | tee -a "$LOG_FILE"
}

log_only() {
    echo "$1" >> "$LOG_FILE"
}

print_header() {
    echo -e "${CYAN}=============================================${NC}"
    echo -e "${CYAN}WordPress Author URL Comment Deletion${NC}"
    echo -e "${CYAN}Deletes comments from authors with URLs${NC}"
    echo -e "${CYAN}Batch size: $BATCH_SIZE${NC}"
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
    
    [ -z "$PREFIX" ] && PREFIX="wp_"
    
    if [ -z "$DB_NAME" ] || [ -z "$DB_USER" ]; then
        return 1
    fi
    
    return 0
}

count_matching_comments() {
    mysql -h "$DB_HOST" -u "$DB_USER" -p"$DB_PASS" "$DB_NAME" -sN -e "
        SELECT COUNT(*)
        FROM ${PREFIX}comments
        WHERE comment_author LIKE '%http://%' 
           OR comment_author LIKE '%https://%'
           OR comment_author_email LIKE '%http://%' 
           OR comment_author_email LIKE '%https://%'
           OR comment_author_url LIKE '%http://%' 
           OR comment_author_url LIKE '%https://%';
    " 2>/dev/null
}

get_comment_ids() {
    local limit=$1
    
    mysql -h "$DB_HOST" -u "$DB_USER" -p"$DB_PASS" "$DB_NAME" -sN -e "
        SELECT comment_ID
        FROM ${PREFIX}comments
        WHERE comment_author LIKE '%http://%' 
           OR comment_author LIKE '%https://%'
           OR comment_author_email LIKE '%http://%' 
           OR comment_author_email LIKE '%https://%'
           OR comment_author_url LIKE '%http://%' 
           OR comment_author_url LIKE '%https://%'
        LIMIT $limit;
    " 2>/dev/null
}

delete_comments_batch() {
    local comment_ids=$1
    
    mysql -h "$DB_HOST" -u "$DB_USER" -p"$DB_PASS" "$DB_NAME" -e "
        DELETE FROM ${PREFIX}commentmeta WHERE comment_id IN ($comment_ids);
    " 2>/dev/null
    
    if [ $? -ne 0 ]; then
        return 1
    fi
    
    mysql -h "$DB_HOST" -u "$DB_USER" -p"$DB_PASS" "$DB_NAME" -e "
        DELETE FROM ${PREFIX}comments WHERE comment_ID IN ($comment_ids);
    " 2>/dev/null
    
    if [ $? -ne 0 ]; then
        return 1
    fi
    
    return 0
}

delete_matching_comments() {
    local total_count=$1
    
    if [ "$total_count" -eq 0 ]; then
        return 0
    fi
    
    echo -e "${BLUE}Processing $total_count comments in batches of $BATCH_SIZE...${NC}"
    
    local deleted_count=0
    local batch_num=0
    
    while [ $deleted_count -lt $total_count ]; do
        batch_num=$((batch_num + 1))
        
        local comment_ids=$(get_comment_ids $BATCH_SIZE)
        
        if [ -z "$comment_ids" ]; then
            break
        fi
        
        local batch_size=$(echo "$comment_ids" | wc -l)
        comment_ids=$(echo "$comment_ids" | tr '\n' ',' | sed 's/,$//')
        
        echo -e "${GRAY}  Batch $batch_num ($batch_size comments)...${NC}"
        
        if delete_comments_batch "$comment_ids"; then
            deleted_count=$((deleted_count + batch_size))
            echo -e "${GRAY}    ✓ Deleted $batch_size comments${NC}"
        else
            echo -e "${RED}    Error deleting batch $batch_num${NC}"
            log_only "Error deleting batch $batch_num"
            return 1
        fi
        
        sleep 0.1
    done
    
    SITE_DELETED_COMMENTS=$deleted_count
    return 0
}

print_header

echo -e "${YELLOW}Select mode:${NC}"
echo -e "  1) Normal mode (delete comments from authors with URLs)"
echo -e "  2) Diagnostic mode (check only, no deletion)"
read -p "$(echo -e ${YELLOW}Enter choice [1-2]: ${NC})" MODE_CHOICE

if [[ ! "$MODE_CHOICE" =~ ^[1-2]$ ]]; then
    echo -e "${RED}Invalid choice. Exiting.${NC}"
    exit 1
fi

DIAGNOSTIC_MODE=false
[ "$MODE_CHOICE" = "2" ] && DIAGNOSTIC_MODE=true

echo

if [ "$DIAGNOSTIC_MODE" = false ]; then
    echo -e "${YELLOW}This
