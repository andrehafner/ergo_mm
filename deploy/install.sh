#!/bin/bash
# ============================================================
# ERGO Market Maker Monitoring System - Server Installation Script
# For Ubuntu/Debian with nginx
# ============================================================

set -e

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

echo -e "${GREEN}============================================================${NC}"
echo -e "${GREEN}  ERGO Market Maker - Server Installation${NC}"
echo -e "${GREEN}============================================================${NC}"
echo ""

# Check if running as root
if [ "$EUID" -ne 0 ]; then
    echo -e "${RED}Please run as root (use sudo)${NC}"
    exit 1
fi

# Variables
INSTALL_DIR="/var/www/ergo_mm"
CGI_DIR="${INSTALL_DIR}/cgi-bin"
DOMAIN="mm.ergoplatform.com"

# ============================================================
# STEP 1: Update system and install dependencies
# ============================================================
echo -e "${YELLOW}[1/8] Updating system and installing dependencies...${NC}"
apt-get update
apt-get install -y \
    nginx \
    fcgiwrap \
    mysql-server \
    mysql-client \
    perl \
    libdbi-perl \
    libdbd-mysql-perl \
    libjson-perl \
    libwww-perl \
    libdigest-sha-perl \
    libcgi-pm-perl \
    libtime-hires-perl \
    certbot \
    python3-certbot-nginx

echo -e "${GREEN}Dependencies installed successfully${NC}"

# ============================================================
# STEP 2: Start and enable services
# ============================================================
echo -e "${YELLOW}[2/8] Starting services...${NC}"
systemctl start nginx
systemctl enable nginx
systemctl start fcgiwrap
systemctl enable fcgiwrap
systemctl start mysql
systemctl enable mysql

echo -e "${GREEN}Services started${NC}"

# ============================================================
# STEP 3: Create directory structure
# ============================================================
echo -e "${YELLOW}[3/8] Creating directory structure...${NC}"
mkdir -p ${INSTALL_DIR}
mkdir -p ${CGI_DIR}
mkdir -p /var/log/ergo_mm

echo -e "${GREEN}Directories created${NC}"

# ============================================================
# STEP 4: Copy application files
# ============================================================
echo -e "${YELLOW}[4/8] Copying application files...${NC}"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

cp "${SCRIPT_DIR}/dashboard.pl" ${CGI_DIR}/
cp "${SCRIPT_DIR}/api.pl" ${CGI_DIR}/
cp "${SCRIPT_DIR}/monitor.pl" ${CGI_DIR}/

chmod 755 ${CGI_DIR}/*.pl
chown -R www-data:www-data ${INSTALL_DIR}

echo -e "${GREEN}Application files copied${NC}"

# ============================================================
# STEP 5: Setup MySQL
# ============================================================
echo -e "${YELLOW}[5/8] Setting up MySQL...${NC}"
echo ""
echo "You will be prompted to set/confirm the MySQL root password."
echo ""

# Check if MySQL is already secured
if mysql -u root -e "SELECT 1" 2>/dev/null; then
    echo "MySQL root has no password set. Setting up now..."
    read -s -p "Enter new MySQL root password: " MYSQL_ROOT_PASSWORD
    echo ""
    mysql -u root -e "ALTER USER 'root'@'localhost' IDENTIFIED WITH mysql_native_password BY '${MYSQL_ROOT_PASSWORD}';"
    mysql -u root -e "FLUSH PRIVILEGES;"
else
    read -s -p "Enter existing MySQL root password: " MYSQL_ROOT_PASSWORD
    echo ""
fi

# Create the database schema
mysql -u root -p"${MYSQL_ROOT_PASSWORD}" < "${SCRIPT_DIR}/sql/schema.sql"

# Apply additional tables if they exist
if [ -f "${SCRIPT_DIR}/sql/add_user_tables.sql" ]; then
    mysql -u root -p"${MYSQL_ROOT_PASSWORD}" ergo_mm < "${SCRIPT_DIR}/sql/add_user_tables.sql" 2>/dev/null || true
fi

# Enable event scheduler for automatic cleanup
mysql -u root -p"${MYSQL_ROOT_PASSWORD}" -e "SET GLOBAL event_scheduler = ON;"

echo -e "${GREEN}MySQL database created${NC}"

# ============================================================
# STEP 6: Create configuration files
# ============================================================
echo -e "${YELLOW}[6/8] Creating configuration files...${NC}"

# MySQL password file
echo "${MYSQL_ROOT_PASSWORD}" > ${CGI_DIR}/sql.txt
chmod 600 ${CGI_DIR}/sql.txt
chown www-data:www-data ${CGI_DIR}/sql.txt

# Also create in legacy location for compatibility
mkdir -p /usr/lib/cgi-bin
echo "${MYSQL_ROOT_PASSWORD}" > /usr/lib/cgi-bin/sql.txt
chmod 600 /usr/lib/cgi-bin/sql.txt

# API keys config template
cat > ${CGI_DIR}/api_keys.conf.example << 'EOF'
# Exchange API Keys Configuration
# Copy this to api_keys.conf and fill in your keys
# chmod 600 api_keys.conf

# MEXC (for balance/order tracking)
MEXC_ACCESS_KEY=your_mexc_access_key
MEXC_SECRET_KEY=your_mexc_secret_key

# KuCoin (for balance/order tracking)
KUCOIN_KEY=your_kucoin_api_key
KUCOIN_SECRET=your_kucoin_secret
KUCOIN_PASSPHRASE=your_kucoin_passphrase
EOF

echo -e "${GREEN}Configuration files created${NC}"

# ============================================================
# STEP 7: Setup nginx
# ============================================================
echo -e "${YELLOW}[7/8] Configuring nginx...${NC}"

# Copy nginx config
cp "${SCRIPT_DIR}/deploy/nginx/mm.ergoplatform.com.conf" /etc/nginx/sites-available/

# Enable the site
ln -sf /etc/nginx/sites-available/mm.ergoplatform.com.conf /etc/nginx/sites-enabled/

# Remove default site if exists
rm -f /etc/nginx/sites-enabled/default

# Test nginx config
nginx -t

# Reload nginx
systemctl reload nginx

echo -e "${GREEN}Nginx configured${NC}"

# ============================================================
# STEP 8: Setup cron for monitoring
# ============================================================
echo -e "${YELLOW}[8/8] Setting up monitoring cron job...${NC}"

# Create cron job for monitor.pl (every 5 minutes)
CRON_CMD="*/5 * * * * /usr/bin/perl ${CGI_DIR}/monitor.pl >> /var/log/ergo_mm/monitor.log 2>&1"
(crontab -l 2>/dev/null | grep -v "monitor.pl"; echo "$CRON_CMD") | crontab -

# Create log file with proper permissions
touch /var/log/ergo_mm/monitor.log
chmod 666 /var/log/ergo_mm/monitor.log

echo -e "${GREEN}Cron job configured${NC}"

# ============================================================
# COMPLETE
# ============================================================
echo ""
echo -e "${GREEN}============================================================${NC}"
echo -e "${GREEN}  Installation Complete!${NC}"
echo -e "${GREEN}============================================================${NC}"
echo ""
echo "Next steps:"
echo ""
echo "1. Test the dashboard:"
echo "   http://${DOMAIN}/cgi-bin/dashboard.pl"
echo ""
echo "2. Setup SSL certificate (recommended):"
echo "   sudo certbot --nginx -d ${DOMAIN}"
echo ""
echo "3. (Optional) Configure exchange API keys for balance tracking:"
echo "   cp ${CGI_DIR}/api_keys.conf.example ${CGI_DIR}/api_keys.conf"
echo "   nano ${CGI_DIR}/api_keys.conf"
echo "   chmod 600 ${CGI_DIR}/api_keys.conf"
echo ""
echo "4. Change the dashboard password:"
echo "   Edit ${CGI_DIR}/dashboard.pl and change DASHBOARD_PASSWORD"
echo ""
echo "5. Monitor logs:"
echo "   tail -f /var/log/ergo_mm/monitor.log"
echo "   tail -f /var/log/nginx/mm.ergoplatform.com.error.log"
echo ""
echo "Default login password: ergo_IS_FOR_anyone"
echo ""
