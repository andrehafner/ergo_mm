#!/bin/bash
# ============================================================
# ERGO Market Maker - Data Migration Script
# Migrate data from old server to new server
# ============================================================

set -e

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
NC='\033[0m'

echo -e "${GREEN}============================================================${NC}"
echo -e "${GREEN}  ERGO Market Maker - Data Migration${NC}"
echo -e "${GREEN}============================================================${NC}"
echo ""

# ============================================================
# USAGE
# ============================================================
show_usage() {
    echo "Usage:"
    echo ""
    echo "  ON OLD SERVER (to export):"
    echo "    $0 export"
    echo ""
    echo "  ON NEW SERVER (to import):"
    echo "    $0 import /path/to/ergo_mm_backup.sql.gz"
    echo ""
    echo "  FULL MIGRATION (from new server via SSH):"
    echo "    $0 migrate user@old-server.com"
    echo ""
}

# ============================================================
# EXPORT (run on old server)
# ============================================================
do_export() {
    echo -e "${YELLOW}Exporting database from old server...${NC}"

    BACKUP_FILE="ergo_mm_backup_$(date +%Y%m%d_%H%M%S).sql.gz"

    read -s -p "Enter MySQL root password: " MYSQL_PASSWORD
    echo ""

    echo -e "${CYAN}Dumping database...${NC}"
    mysqldump -u root -p"${MYSQL_PASSWORD}" \
        --single-transaction \
        --routines \
        --triggers \
        --events \
        ergo_mm | gzip > "${BACKUP_FILE}"

    echo -e "${GREEN}Database exported to: ${BACKUP_FILE}${NC}"
    echo ""
    echo "File size: $(ls -lh ${BACKUP_FILE} | awk '{print $5}')"
    echo ""
    echo "Transfer this file to your new server:"
    echo "  scp ${BACKUP_FILE} user@new-server:/tmp/"
    echo ""
    echo "Then on the new server run:"
    echo "  $0 import /tmp/${BACKUP_FILE}"
}

# ============================================================
# IMPORT (run on new server)
# ============================================================
do_import() {
    BACKUP_FILE="$1"

    if [ -z "${BACKUP_FILE}" ]; then
        echo -e "${RED}Error: Please specify the backup file${NC}"
        show_usage
        exit 1
    fi

    if [ ! -f "${BACKUP_FILE}" ]; then
        echo -e "${RED}Error: File not found: ${BACKUP_FILE}${NC}"
        exit 1
    fi

    echo -e "${YELLOW}Importing database to new server...${NC}"

    read -s -p "Enter MySQL root password: " MYSQL_PASSWORD
    echo ""

    echo -e "${CYAN}Creating database if not exists...${NC}"
    mysql -u root -p"${MYSQL_PASSWORD}" -e "CREATE DATABASE IF NOT EXISTS ergo_mm CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci;"

    echo -e "${CYAN}Importing data (this may take a while)...${NC}"
    gunzip -c "${BACKUP_FILE}" | mysql -u root -p"${MYSQL_PASSWORD}" ergo_mm

    echo -e "${GREEN}Database imported successfully!${NC}"
    echo ""

    # Show record counts
    echo -e "${CYAN}Record counts:${NC}"
    mysql -u root -p"${MYSQL_PASSWORD}" ergo_mm -e "
        SELECT 'price_data' as table_name, COUNT(*) as records FROM price_data
        UNION ALL
        SELECT 'orderbook_depth', COUNT(*) FROM orderbook_depth
        UNION ALL
        SELECT 'trades', COUNT(*) FROM trades
        UNION ALL
        SELECT 'alerts_log', COUNT(*) FROM alerts_log
        UNION ALL
        SELECT 'user_balances', COUNT(*) FROM user_balances
        UNION ALL
        SELECT 'config', COUNT(*) FROM config;
    "
}

# ============================================================
# FULL MIGRATION (run on new server, pulls from old via SSH)
# ============================================================
do_migrate() {
    OLD_SERVER="$1"

    if [ -z "${OLD_SERVER}" ]; then
        echo -e "${RED}Error: Please specify the old server (user@hostname)${NC}"
        show_usage
        exit 1
    fi

    echo -e "${YELLOW}Full migration from ${OLD_SERVER}${NC}"
    echo ""

    TEMP_BACKUP="/tmp/ergo_mm_migration_$(date +%Y%m%d_%H%M%S).sql.gz"

    echo -e "${CYAN}Step 1: Connecting to old server and dumping database...${NC}"
    read -s -p "Enter MySQL root password on OLD server: " OLD_MYSQL_PASSWORD
    echo ""

    ssh "${OLD_SERVER}" "mysqldump -u root -p'${OLD_MYSQL_PASSWORD}' \
        --single-transaction \
        --routines \
        --triggers \
        --events \
        ergo_mm | gzip" > "${TEMP_BACKUP}"

    echo -e "${GREEN}Database dump downloaded: ${TEMP_BACKUP}${NC}"
    echo "File size: $(ls -lh ${TEMP_BACKUP} | awk '{print $5}')"
    echo ""

    echo -e "${CYAN}Step 2: Importing to new server...${NC}"
    read -s -p "Enter MySQL root password on NEW server: " NEW_MYSQL_PASSWORD
    echo ""

    mysql -u root -p"${NEW_MYSQL_PASSWORD}" -e "CREATE DATABASE IF NOT EXISTS ergo_mm CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci;"
    gunzip -c "${TEMP_BACKUP}" | mysql -u root -p"${NEW_MYSQL_PASSWORD}" ergo_mm

    echo -e "${GREEN}Database imported!${NC}"
    echo ""

    echo -e "${CYAN}Step 3: Copying configuration files...${NC}"

    # Try to copy API keys config if it exists
    ssh "${OLD_SERVER}" "cat /usr/lib/cgi-bin/api_keys.conf 2>/dev/null" > /var/www/ergo_mm/cgi-bin/api_keys.conf 2>/dev/null || true
    if [ -s /var/www/ergo_mm/cgi-bin/api_keys.conf ]; then
        chmod 600 /var/www/ergo_mm/cgi-bin/api_keys.conf
        chown www-data:www-data /var/www/ergo_mm/cgi-bin/api_keys.conf
        echo -e "${GREEN}API keys config copied${NC}"
    else
        echo -e "${YELLOW}No API keys config found on old server (optional)${NC}"
    fi

    # Cleanup
    rm -f "${TEMP_BACKUP}"

    echo ""
    echo -e "${GREEN}============================================================${NC}"
    echo -e "${GREEN}  Migration Complete!${NC}"
    echo -e "${GREEN}============================================================${NC}"
    echo ""
    echo "Your data has been migrated. Test the dashboard at:"
    echo "  http://mm.ergoplatform.com/cgi-bin/dashboard.pl"
    echo ""
}

# ============================================================
# MAIN
# ============================================================
case "${1}" in
    export)
        do_export
        ;;
    import)
        do_import "$2"
        ;;
    migrate)
        do_migrate "$2"
        ;;
    *)
        show_usage
        exit 1
        ;;
esac
