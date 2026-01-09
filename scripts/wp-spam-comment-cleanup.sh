#!/bin/bash
# =====================================
# WordPress Spam Comment Removal Script
# Removes comments matching spam patterns
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
BATCH_SIZE=100  # Process deletions in batches

# Spam patterns file
SPAM_PATTERNS_URL="https://raw.githubusercontent.com/M-Saadawy/WordPress-spam-user-list/main/comments.txt"
SPAM_PATTERNS_FILE="/tmp/spam_patterns_$TIMESTAMP.txt"

# Create log directory
mkdir -p "$LOG_DIR"
LOG_FILE="$LOG_DIR/spam_comment_deletion_$TIMESTAMP.log"

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
    echo -e "${CYAN}==== WordPress Spam Comment Removal ========${NC}"
    echo -e "${CYAN}==== Batch size: $BATCH_SIZE ===============${NC}"
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
    
    return 0
}

load_spam_patterns() {
    if [ ! -f "$SPAM_PATTERNS_FILE" ]; then
        echo -e "${RED}Error: Spam patterns file not found: $SPAM_PATTERNS_FILE${NC}"
        return 1
    fi
    
    # Read patterns into array, skip empty lines and comments
    mapfile -t SPAM_PATTERNS < <(grep -v '^#' "$SPAM_PATTERNS_FILE" | grep -v '^[[:space:]]*$')
    
    if [ ${#SPAM_PATTERNS[@]} -eq 0 ]; then
        echo -e "${RED}Error: No patterns found in file${NC}"
        return 1
    fi
    
    echo -e "${GREEN}Loaded ${#SPAM_PATTERNS[@]} spam patterns${NC}"
    log_only "Loaded ${#SPAM_PATTERNS[@]} spam patterns"
    
    # Show first 10 as preview
    echo -e "${YELLOW}Preview (first 10 patterns):${NC}"
    for i in {0..9}; do
        if [ $i -lt ${#SPAM_PATTERNS[@]} ]; then
            echo -e "${GRAY}  - ${SPAM_PATTERNS[$i]}${NC}"
            log_only "  Pattern: ${SPAM_PATTERNS[$i]}"
        fi
    done
    
    if [ ${#SPAM_PATTERNS[@]} -gt 10 ]; then
        echo -e "${GRAY}  ... and $((${#SPAM_PATTERNS[@]} - 10)) more${NC}"
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
    
    # Build SQL conditions for each pattern
    # Check in: comment_content, comment_author, comment_author_email, comment_author_url
    for pattern in "${SPAM_PATTERNS[@]}"; do
        # Escape single quotes for SQL
        local escaped_pattern=$(echo "$pattern" | sed "s/'/''/g")
        
        if [ "$first" = true ]; then
            conditions="(comment_content LIKE '%${escaped_pattern}%' 
                      OR comment_author LIKE '%${escaped_pattern}%' 
                      OR comment_author_email LIKE '%${escaped_pattern}%' 
                      OR comment_author_url LIKE '%${escaped_pattern}%')"
            first=false
        else
            conditions="$conditions 
                     OR (comment_content LIKE '%${escaped_pattern}%' 
                      OR comment_author LIKE '%${escaped_pattern}%' 
                      OR comment_author_email LIKE '%${escaped_pattern}%' 
                      OR comment_author_url LIKE '%${escaped_pattern}%')"
        fi
    done
    
    echo "$conditions"
}

count_spam_comments() {
    local sql_conditions="$1"
    
    mysql -h "$DB_HOST" -u "$DB_USER" -p"$DB_PASS" "$DB_NAME" -sN -e "
        SELECT COUNT(*)
        FROM ${PREFIX}comments
        WHERE $sql_conditions;
    " 2>/dev/null
}

get_spam_comment_ids() {
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
    
    # Delete commentmeta first
    mysql -h "$DB_HOST" -u "$DB_USER" -p"$DB_PASS" "$DB_NAME" -e "
        DELETE FROM ${PREFIX}commentmeta WHERE comment_id IN ($comment_ids);
    " 2>/dev/null
    
    if [ $? -ne 0 ]; then
        return 1
    fi
    
    # Delete comments
    mysql -h "$DB_HOST" -u "$DB_USER" -p"$DB_PASS" "$DB_NAME" -e "
        DELETE FROM ${PREFIX}comments WHERE comment_ID IN ($comment_ids);
    " 2>/dev/null
    
    if [ $? -ne 0 ]; then
        return 1
    fi
    
    return 0
}

delete_spam_comments() {
    local sql_conditions="$1"
    local total_spam_count=$2
    
    if [ "$total_spam_count" -eq 0 ]; then
        return 0
    fi
    
    echo -e "${BLUE}Processing $total_spam_count spam comments in batches of $BATCH_SIZE...${NC}"
    
    local deleted_count=0
    local batch_num=0
    
    while [ $deleted_count -lt $total_spam_count ]; do
        batch_num=$((batch_num + 1))
        
        # Get comment IDs for this batch
        local comment_ids=$(get_spam_comment_ids "$sql_conditions" $BATCH_SIZE)
        
        if [ -z "$comment_ids" ]; then
            # No more comments to delete
            break
        fi
        
        local batch_size=$(echo "$comment_ids" | wc -l)
        
        # Convert to comma-separated list
        comment_ids=$(echo "$comment_ids" | tr '\n' ',' | sed 's/,$//')
        
        echo -e "${GRAY}  Batch $batch_num ($batch_size comments)...${NC}"
        
        # Delete this batch
        if delete_comments_batch "$comment_ids"; then
            deleted_count=$((deleted_count + batch_size))
            echo -e "${GRAY}    ✓ Deleted $batch_size comments${NC}"
        else
            echo -e "${RED}    Error deleting batch $batch_num${NC}"
            log_only "Error deleting batch $batch_num"
            return 1
        fi
        
        # Small delay to avoid overwhelming the database
        sleep 0.1
    done
    
    SITE_DELETED_COMMENTS=$deleted_count
    return 0
}

# =====================================
# Main Script
# =====================================

print_header

# Mode selection
echo -e "${YELLOW}Select mode:${NC}"
echo -e "${WHITE}  1) Normal mode (delete spam comments)${NC}"
echo -e "${WHITE}  2) Diagnostic mode (check only, no deletion)${NC}"
echo -e "${WHITE}  3) Use local spam patterns file${NC}"
read -p "$(echo -e ${YELLOW}Enter choice [1-3]: ${NC})" MODE_CHOICE

if [[ ! "$MODE_CHOICE" =~ ^[1-3]$ ]]; then
    echo -e "${RED}Invalid choice. Exiting.${NC}"
    exit 1
fi

DIAGNOSTIC_MODE=false
USE_LOCAL_FILE=false

case "$MODE_CHOICE" in
    1)
        # Normal mode - download patterns
        ;;
    2)
        # Diagnostic mode - download patterns
        DIAGNOSTIC_MODE=true
        ;;
    3)
        # Use local file
        USE_LOCAL_FILE=true
        read -p "$(echo -e ${YELLOW}Enter path to spam patterns file: ${NC})" LOCAL_FILE_PATH
        
        if [ ! -f "$LOCAL_FILE_PATH" ]; then
            echo -e "${RED}Error: File not found: $LOCAL_FILE_PATH${NC}"
            exit 1
        fi
        
        SPAM_PATTERNS_FILE="$LOCAL_FILE_PATH"
        
        echo
        echo -e "${YELLOW}Delete spam comments using this file?${NC}"
        read -p "$(echo -e ${YELLOW}Type 'yes' to proceed in normal mode, 'check' for diagnostic: ${NC})" LOCAL_CONFIRM
        
        if [ "$LOCAL_CONFIRM" == "check" ]; then
            DIAGNOSTIC_MODE=true
        elif [ "$LOCAL_CONFIRM" != "yes" ]; then
            echo -e "${RED}Aborted by user.${NC}"
            exit 1
        fi
        ;;
esac

# Download spam patterns if needed
if [ "$USE_LOCAL_FILE" = false ]; then
    if ! download_spam_patterns; then
        echo -e "${RED}Failed to download spam patterns. Exiting.${NC}"
        exit 1
    fi
    echo -e "${GREEN}✓ Downloaded spam patterns${NC}"
    echo
fi

# Load spam patterns
if ! load_spam_patterns; then
    echo -e "${RED}Failed to load spam patterns. Exiting.${NC}"
    [ "$USE_LOCAL_FILE" = false ] && rm -f "$SPAM_PATTERNS_FILE"
    exit 1
fi

echo

# Confirmation for normal mode
if [ "$DIAGNOSTIC_MODE" = false ]; then
    echo -e "${YELLOW}This script will permanently delete ALL comments matching the spam patterns.${NC}"
    echo -e "${YELLOW}This includes comment content, author names, emails, and URLs.${NC}"
    echo
    read -p "$(echo -e ${RED}Are you sure? Type 'yes' to proceed: ${NC})" CONFIRM
    
    if [ "$CONFIRM" != "yes" ]; then
        echo -e "${RED}Aborted by user.${NC}"
        [ "$USE_LOCAL_FILE" = false ] && rm -f "$SPAM_PATTERNS_FILE"
        exit 1
    fi
else
    echo -e "${BLUE}Running in DIAGNOSTIC mode - no deletions will occur${NC}"
fi

echo
echo -e "${BLUE}Searching WordPress sites under $BASE_DIR ...${NC}"
echo -e "${GRAY}Log file: $LOG_FILE${NC}"
echo

# Initialize log
{
    echo "=== WordPress Spam Comment Deletion Log ==="
    echo "Timestamp: $(date)"
    echo "Mode: $([ "$DIAGNOSTIC_MODE" = true ] && echo "DIAGNOSTIC" || echo "NORMAL")"
    echo "Batch size: $BATCH_SIZE"
    echo "Patterns file: $([ "$USE_LOCAL_FILE" = true ] && echo "$LOCAL_FILE_PATH" || echo "$SPAM_PATTERNS_URL")"
    echo "========================================"
    echo
} > "$LOG_FILE"

TOTAL_DELETED_COMMENTS=0
SITES_PROCESSED=0
SITES_WITH_SPAM=0

# Build SQL conditions once (reused for all sites)
echo -e "${GRAY}Building SQL query conditions...${NC}"
SQL_CONDITIONS=$(build_sql_conditions)

# Process each WordPress site
for SITE_PATH in $BASE_DIR/*/public_html; do
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
    
    # Count spam comments
    echo -e "${GRAY}Scanning for spam comments...${NC}"
    SPAM_COUNT=$(count_spam_comments "$SQL_CONDITIONS")
    SPAM_COUNT=${SPAM_COUNT:-0}
    
    if [ "$SPAM_COUNT" -eq 0 ]; then
        echo -e "${GREEN}✓ No spam comments found${NC}"
        log_only "No spam comments found"
        echo
        continue
    fi
    
    echo -e "${YELLOW}Found $SPAM_COUNT spam comment(s)${NC}"
    log_only "Found $SPAM_COUNT spam comment(s)"
    
    SITES_WITH_SPAM=$((SITES_WITH_SPAM + 1))
    
    # Show sample of spam comments (first 5)
    echo -e "${YELLOW}Sample spam comments:${NC}"
    mysql -h "$DB_HOST" -u "$DB_USER" -p"$DB_PASS" "$DB_NAME" -sN -e "
        SELECT comment_ID, comment_author, LEFT(comment_content, 50)
        FROM ${PREFIX}comments
        WHERE $SQL_CONDITIONS
        LIMIT 5;
    " 2>/dev/null | while IFS=$'\t' read -r COMMENT_ID AUTHOR CONTENT; do
        echo -e "${GRAY}  - ID: $COMMENT_ID, Author: $AUTHOR${NC}"
        echo -e "${GRAY}    Content: ${CONTENT}...${NC}"
        log_only "  Comment ID: $COMMENT_ID, Author: $AUTHOR"
    done
    
    # Perform deletion or skip in diagnostic mode
    if [ "$DIAGNOSTIC_MODE" = true ]; then
        echo -e "${BLUE}[DIAGNOSTIC] Would delete $SPAM_COUNT spam comments${NC}"
        log_only "[DIAGNOSTIC] Would delete $SPAM_COUNT spam comments"
    else
        if delete_spam_comments "$SQL_CONDITIONS" "$SPAM_COUNT"; then
            echo -e "${GREEN}✓ Deleted $SITE_DELETED_COMMENTS spam comment(s)${NC}"
            log_only "✓ Deleted $SITE_DELETED_COMMENTS spam comment(s)"
            
            TOTAL_DELETED_COMMENTS=$((TOTAL_DELETED_COMMENTS + SITE_DELETED_COMMENTS))
        else
            echo -e "${RED}✗ Deletion failed${NC}"
            log_only "✗ Deletion failed"
        fi
    fi
    
    SITES_PROCESSED=$((SITES_PROCESSED + 1))
    echo
done

# Cleanup temporary file
[ "$USE_LOCAL_FILE" = false ] && rm -f "$SPAM_PATTERNS_FILE"

# =====================================
# Final Summary
# =====================================

{
    echo "========================================"
    echo "Final Summary:"
    echo "Sites processed: $SITES_PROCESSED"
    echo "Sites with spam: $SITES_WITH_SPAM"
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
    echo -e "${BLUE}Sites with spam: $SITES_WITH_SPAM${NC}"
elif [ "$TOTAL_DELETED_COMMENTS" -gt 0 ]; then
    echo -e "${GREEN}Total spam comments deleted: $TOTAL_DELETED_COMMENTS${NC}"
    echo -e "${GREEN}Sites processed: $SITES_PROCESSED${NC}"
    echo -e "${GREEN}Sites with spam: $SITES_WITH_SPAM${NC}"
else
    echo -e "${YELLOW}No spam comments were deleted${NC}"
    echo -e "${YELLOW}Sites processed: $SITES_PROCESSED${NC}"
fi

echo
echo -e "${CYAN}Log file: $LOG_FILE${NC}"
echo -e "${GRAY}Completed: $(date)${NC}"
