#!/bin/bash
# =====================================
# WordPress Comment Link Detector
# Finds NEW links not in known spam list
# =====================================

RED='\033[0;31m'
GREEN='\033[0;32m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
GRAY='\033[0;90m'
NC='\033[0m'

BASE_DIR="/var/www/domains"
TIMESTAMP=$(date +%Y%m%d_%H%M%S)
OUTPUT_FILE="$HOME/detected_links_$TIMESTAMP.txt"
KNOWN_SPAM_URL="https://raw.githubusercontent.com/M-Saadawy/WordPress-spam-user-list/main/comments.txt"
KNOWN_SPAM_FILE="/tmp/known_spam_$TIMESTAMP.txt"
TEMP_COMMENTS="/tmp/comments_$TIMESTAMP.txt"

download_known_spam() {
    echo -e "${BLUE}Downloading known spam patterns...${NC}"
    
    if command -v wget &> /dev/null; then
        wget -q -O "$KNOWN_SPAM_FILE" "$KNOWN_SPAM_URL" 2>/dev/null
    elif command -v curl &> /dev/null; then
        curl -s -o "$KNOWN_SPAM_FILE" "$KNOWN_SPAM_URL" 2>/dev/null
    else
        echo -e "${RED}Error: Neither wget nor curl available${NC}"
        return 1
    fi
    
    if [ ! -f "$KNOWN_SPAM_FILE" ] || [ ! -s "$KNOWN_SPAM_FILE" ]; then
        echo -e "${RED}Error: Failed to download spam list${NC}"
        return 1
    fi
    
    echo -e "${GREEN}✓ Downloaded${NC}"
    return 0
}

load_known_spam() {
    mapfile -t KNOWN_SPAM < <(grep -v '^#' "$KNOWN_SPAM_FILE" | grep -v '^[[:space:]]*$')
    echo -e "${GREEN}Loaded ${#KNOWN_SPAM[@]} patterns${NC}"
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

extract_links() {
    local text="$1"
    echo "$text" | grep -oP 'https?://[^\s<>"]+' | sort -u
}

is_already_known() {
    local link="$1"
    
    for pattern in "${KNOWN_SPAM[@]}"; do
        if [[ "$link" == *"$pattern"* ]] || [[ "$pattern" == *"$link"* ]]; then
            return 0
        fi
    done
    
    return 1
}

echo -e "${CYAN}=============================================${NC}"
echo -e "${CYAN}WordPress Comment Link Detector${NC}"
echo -e "${CYAN}=============================================${NC}"
echo

if ! download_known_spam; then
    exit 1
fi

load_known_spam
echo

echo -e "${BLUE}Scanning WordPress sites...${NC}"
echo -e "${GRAY}Output: $OUTPUT_FILE${NC}"
echo

> "$OUTPUT_FILE"

for SITE_PATH in $BASE_DIR/*/public_html; do
    
    if [ ! -f "$SITE_PATH/wp-config.php" ]; then
        continue
    fi
    
    echo -e "${CYAN}Checking: $SITE_PATH${NC}"
    
    if ! extract_db_config "$SITE_PATH"; then
        echo -e "${RED}  Error: Could not read config${NC}"
        continue
    fi
    
    mysql -h "$DB_HOST" -u "$DB_USER" -p"$DB_PASS" "$DB_NAME" -sN -e "
        SELECT comment_author_url, comment_content
        FROM ${PREFIX}comments
        WHERE comment_content LIKE '%http%' 
           OR comment_author_url LIKE '%http%';
    " 2>/dev/null > "$TEMP_COMMENTS"
    
    while IFS=$'\t' read -r AUTHOR_URL CONTENT; do
        
        if [ -n "$CONTENT" ]; then
            extract_links "$CONTENT" >> "$OUTPUT_FILE"
        fi
        
        if [ -n "$AUTHOR_URL" ] && [[ "$AUTHOR_URL" == http* ]]; then
            echo "$AUTHOR_URL" >> "$OUTPUT_FILE"
        fi
        
    done < "$TEMP_COMMENTS"
    
    rm -f "$TEMP_COMMENTS"
    
done

echo -e "${BLUE}Filtering known spam...${NC}"

TEMP_OUTPUT="/tmp/output_$TIMESTAMP.txt"
> "$TEMP_OUTPUT"

sort -u "$OUTPUT_FILE" | while read -r LINK; do
    if [ -n "$LINK" ] && ! is_already_known "$LINK"; then
        echo "$LINK" >> "$TEMP_OUTPUT"
    fi
done

mv "$TEMP_OUTPUT" "$OUTPUT_FILE"

rm -f "$KNOWN_SPAM_FILE"

LINK_COUNT=$(wc -l < "$OUTPUT_FILE")

echo
echo -e "${CYAN}=============================================${NC}"
echo -e "${GREEN}✓ Complete${NC}"
echo -e "${GREEN}Found $LINK_COUNT new links${NC}"
echo -e "${CYAN}Saved to: $OUTPUT_FILE${NC}"
echo -e "${CYAN}=============================================${NC}"
