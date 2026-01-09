#!/bin/bash
# =====================================
# WordPress Spam Author Comment Deletion
# Deletes ALL comments from authors matching spam patterns
# Searches ONLY in author fields (name, email, URL)
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
LOG_FILE="$LOG_DIR/spam_author_deletion_$TIMESTAMP.log"
BATCH_SIZE=100

SPAM_PATTERNS_URL="https://raw.githubusercontent.com/M-Saadawy/WordPress-spam-user-list/main/comments.txt"
SPAM_PATTERNS_FILE="/tmp/spam_patterns_$TIMESTAMP.txt"

mkdir -p "$LOG_DIR"

log_message() {
    echo "$1" | tee -a "$LOG_FILE"
}

log_only() {
    echo "$1" >> "$LOG_FILE"
}

print_header() {
    echo -e "${CYAN}=============================================${NC}"
    echo -e "${CYAN}WordPress Spam Author Comment Deletion${NC}"
    echo -e "${CYAN}Searches author name/email/URL only${NC}"
    echo -e "${CYAN}Batch size: $BATCH_SIZE${NC}"
    echo -e "${CYAN}=============================================${NC}"
    echo
}

download_spam_patterns() {
    echo -e "${BLUE}Downloading spam patterns from GitHub...${NC}"
    
    if command -v wget &> /dev/null; then
        wget -q -O "$SPAM_PATTERNS_FILE" "$SPAM_PATTERNS_URL" 2>/dev/null
    elif command -v curl &> /dev/null; then
        curl -s -o "$SPAM_PATTERNS_FILE" "$SPAM_PATTERNS_URL" 2>/dev/null
    else
        echo -e "${RED}Error: Neither wget nor curl is available${NC}"
        return 1
    fi
    
    if [ ! -f "$SPAM_PATTERNS_FILE" ] || [ ! -s "$SPAM_PATTERNS_FILE" ]; then
        echo -e "${RED}Error: Failed to download spam patterns${NC}"
        return 1
    fi
    
    echo -e "${GREEN}✓ Downloaded spam patterns${NC}"
    return 0
}

load_spam_patterns() {
    mapfile -t PATTERNS < <(grep -v '^#' "$SPAM_PATTERNS_FILE" | grep -v '^[[:space:]]*$')
    
    if [ ${#PATTERNS[@]} -eq 0 ]; then
        echo -e "${RED}Error: No patterns found${NC}"
        return 1
    fi
    
    echo -e "${GREEN}Loaded ${#PATTERNS[@]} spam patterns${NC}"
    log_only "Loaded ${#PATTERNS[@]} patterns from GitHub"
    
    echo -e "${YELLOW}Preview (first 10):${NC}"
    for i in {0..9}; do
        if [ $i -lt ${#PATTERNS[@]} ]; then
            echo -e "${GRAY}  - ${PATTERNS[$i]}${NC}"
            log_only "  Pattern: ${PATTERNS[$i]}"
        fi
    done
    
    if [ ${#PATTERNS[@]} -gt 10 ]; then
        echo -e "${GRAY}  ... and $((${#PATTERNS[@]} - 10)) more${NC}"
    fi
    
    return 0
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

build_sql_conditions() {
    local conditions=""
    local first=true
    
    # ONLY search in author fields, NOT comment content
    for pattern in "${PATTERNS[@]}"; do
        local escaped_pattern=$(echo "$pattern" | sed "s/'/''/g")
        
        if [ "$first" = true ]; then
            conditions="(comment_author LIKE '%${escaped_pattern}%' 
                      OR comment_author_email LIKE '%${escaped_pattern}%' 
                      OR comment_author_url LIKE '%${escaped_pattern}%')"
            first=false
        else
            conditions="$conditions 
                     OR (comment_author LIKE '%${escaped_pattern}%' 
                      OR comment_author_email LIKE '%${escaped_pattern}%' 
                      OR comment_author_url LIKE '%${escaped_pattern}%')"
        fi
    done
    
    echo "$conditions"
}

count_matching_comments() {
    local sql_conditions="$1"
    
    mysql -h "$DB_HOST" -u "$DB_USER" -p"$DB_PASS" "$DB_NAME" -sN -e "
        SELECT COUNT(*)
        FROM ${PREFIX}comments
        WHERE $sql_conditions;
    " 2>/dev/null
}

get_comment_ids() {
    local sql_conditions="$1"
    local limit=$2
    
    mysql -h "$DB_HOST" -u "$DB_USER" -p"$DB_PASS" "$DB_NAME" -sN -e "
        SELECT comment_ID
        FROM ${PREFIX}comments
        WHERE $sql_conditions
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
    local sql_conditions="$1"
    local total_count=$2
    
    if [ "$total_count" -eq 0 ]; then
        return 0
    fi
    
    echo -e "${BLUE}Processing $total_count comments in batches of $BATCH_SIZE...${NC}"
    
    local deleted_count=0
    local batch_num=0
    
    while [ $deleted_count -lt $total_count ]; do
        batch_num=$((batch_num + 1))
        
        local comment_ids=$(get_comment_ids "$sql_conditions" $BATCH_SIZE)
        
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
echo -e "  1) Normal mode (delete all comments from spam authors)"
echo -e "  2) Diagnostic mode (check only, no deletion)"
read -p "$(echo -e ${YELLOW}Enter choice [1-2]: ${NC})" MODE_CHOICE

if [[ ! "$MODE_CHOICE" =~ ^[1-2]$ ]]; then
    echo -e "${RED}Invalid choice. Exiting.${NC}"
    exit 1
fi

DIAGNOSTIC_MODE=false
[ "$MODE_CHOICE" = "2" ] && DIAGNOSTIC_MODE=true

echo

if ! download_spam_patterns; then
    exit 1
fi

if ! load_spam_patterns; then
    rm -f "$SPAM_PATTERNS_FILE"
    exit 1
fi

echo

if [ "$DIAGNOSTIC_MODE" = false ]; then
    echo -e "${YELLOW}This will permanently delete ALL comments from authors whose info matches the spam list.${NC}"
    echo -e "${YELLOW}Searches in: author name, author email, author URL${NC}"
    echo
    read -p "$(echo -e ${RED}Type 'yes' to proceed: ${NC})" CONFIRM
    
    if [ "$CONFIRM" != "yes" ]; then
        echo -e "${RED}Aborted.${NC}"
        rm -f "$SPAM_PATTERNS_FILE"
        exit 1
    fi
else
    echo -e "${BLUE}Running in DIAGNOSTIC mode - no deletions${NC}"
fi

echo
echo -e "${BLUE}Searching WordPress sites under $BASE_DIR ...${NC}"
echo -e "${GRAY}Log file: $LOG_FILE${NC}"
echo

{
    echo "=== WordPress Spam Author Comment Deletion Log ==="
    echo "Timestamp: $(date)"
    echo "Mode: $([ "$DIAGNOSTIC_MODE" = true ] && echo "DIAGNOSTIC" || echo "NORMAL")"
    echo "Pattern source: $SPAM_PATTERNS_URL"
    echo "Search scope: Author name, email, URL only"
    echo "Batch size: $BATCH_SIZE"
    echo "========================================"
    echo
} > "$LOG_FILE"

TOTAL_DELETED_COMMENTS=0
SITES_PROCESSED=0
SITES_WITH_MATCHES=0

echo -e "${GRAY}Building SQL conditions (author fields only)...${NC}"
SQL_CONDITIONS=$(build_sql_conditions)

for SITE_PATH in $BASE_DIR/*/public_html; do
    
    if [ ! -f "$SITE_PATH/wp-config.php" ]; then
        continue
    fi
    
    echo -e "${CYAN}-------------------------------------------${NC}"
    echo -e "${CYAN}Site: $SITE_PATH${NC}"
    log_only "Site: $SITE_PATH"
    
    if ! extract_db_config "$SITE_PATH"; then
        echo -e "${RED}Error: Could not extract database credentials${NC}"
        log_only "Error: Could not extract database credentials"
        echo
        continue
    fi
    
    echo -e "${GRAY}Database: $DB_NAME, Prefix: $PREFIX${NC}"
    log_only "Database: $DB_NAME, Prefix: $PREFIX"
    
    echo -e "${GRAY}Scanning for spam authors...${NC}"
    MATCH_COUNT=$(count_matching_comments "$SQL_CONDITIONS")
    MATCH_COUNT=${MATCH_COUNT:-0}
    
    if [ "$MATCH_COUNT" -eq 0 ]; then
        echo -e "${GREEN}✓ No spam authors found${NC}"
        log_only "No spam authors found"
        echo
        continue
    fi
    
    echo -e "${YELLOW}Found $MATCH_COUNT comment(s) from spam authors${NC}"
    log_only "Found $MATCH_COUNT comment(s) from spam authors"
    
    SITES_WITH_MATCHES=$((SITES_WITH_MATCHES + 1))
    
    echo -e "${YELLOW}Sample spam authors (first 5):${NC}"
    mysql -h "$DB_HOST" -u "$DB_USER" -p"$DB_PASS" "$DB_NAME" -sN -e "
        SELECT DISTINCT comment_author, comment_author_email, comment_author_url
        FROM ${PREFIX}comments
        WHERE $SQL_CONDITIONS
        LIMIT 5;
    " 2>/dev/null | while IFS=$'\t' read -r AUTHOR EMAIL URL; do
        echo -e "${GRAY}  - Author: $AUTHOR${NC}"
        echo -e "${GRAY}    Email: $EMAIL${NC}"
        echo -e "${GRAY}    URL: $URL${NC}"
        log_only "  Spam author: $AUTHOR | $EMAIL | $URL"
    done
    
    if [ "$DIAGNOSTIC_MODE" = true ]; then
        echo -e "${BLUE}[DIAGNOSTIC] Would delete $MATCH_COUNT comments${NC}"
        log_only "[DIAGNOSTIC] Would delete $MATCH_COUNT comments"
    else
        if delete_matching_comments "$SQL_CONDITIONS" "$MATCH_COUNT"; then
            echo -e "${GREEN}✓ Deleted $SITE_DELETED_COMMENTS comment(s)${NC}"
            log_only "✓ Deleted $SITE_DELETED_COMMENTS comment(s)"
            
            TOTAL_DELETED_COMMENTS=$((TOTAL_DELETED_COMMENTS + SITE_DELETED_COMMENTS))
        else
            echo -e "${RED}✗ Deletion failed${NC}"
            log_only "✗ Deletion failed"
        fi
    fi
    
    SITES_PROCESSED=$((SITES_PROCESSED + 1))
    echo
done

rm -f "$SPAM_PATTERNS_FILE"

{
    echo "========================================"
    echo "Final Summary:"
    echo "Sites processed: $SITES_PROCESSED"
    echo "Sites with spam authors: $SITES_WITH_MATCHES"
    echo "Comments deleted: $TOTAL_DELETED_COMMENTS"
    echo "========================================"
} >> "$LOG_FILE"

echo -e "${CYAN}=============================================${NC}"
echo -e "${CYAN}Summary${NC}"
echo -e "${CYAN}=============================================${NC}"
echo

if [ "$DIAGNOSTIC_MODE" = true ]; then
    echo -e "${BLUE}Diagnostic mode - no deletions performed${NC}"
    echo -e "${BLUE}Sites scanned: $SITES_PROCESSED${NC}"
    echo -e "${BLUE}Sites with spam authors: $SITES_WITH_MATCHES${NC}"
elif [ "$TOTAL_DELETED_COMMENTS" -gt 0 ]; then
    echo -e "${GREEN}Total comments deleted: $TOTAL_DELETED_COMMENTS${NC}"
    echo -e "${GREEN}Sites processed: $SITES_PROCESSED${NC}"
    echo -e "${GREEN}Sites with spam authors: $SITES_WITH_MATCHES${NC}"
else
    echo -e "${YELLOW}No comments were deleted${NC}"
    echo -e "${YELLOW}Sites processed: $SITES_PROCESSED${NC}"
fi

echo
echo -e "${CYAN}Log file: $LOG_FILE${NC}"
echo -e "${GRAY}Completed: $(date)${NC}"
