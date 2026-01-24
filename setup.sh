#!/bin/bash
# ============================================================
# ERGO Market Maker Bot - Setup Script
# ============================================================

set -e

echo "=============================================="
echo "ERGO Market Maker Bot - Setup"
echo "=============================================="

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

# Check if running as root or with sudo
if [ "$EUID" -ne 0 ]; then
    echo -e "${YELLOW}Note: Some operations may require sudo access${NC}"
fi

# Get script directory
SCRIPT_DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" && pwd )"

echo ""
echo "Step 1: Checking dependencies..."
echo "----------------------------------------------"

# Check for Perl
if command -v perl &> /dev/null; then
    echo -e "${GREEN}[OK]${NC} Perl found: $(perl -v | head -2 | tail -1)"
else
    echo -e "${RED}[ERROR]${NC} Perl not found. Please install Perl first."
    exit 1
fi

# Check for MySQL client
if command -v mysql &> /dev/null; then
    echo -e "${GREEN}[OK]${NC} MySQL client found"
else
    echo -e "${RED}[ERROR]${NC} MySQL client not found. Please install mysql-client."
    exit 1
fi

# Check for required Perl modules
echo ""
echo "Checking Perl modules..."

MODULES=("DBI" "DBD::mysql" "LWP::UserAgent" "JSON" "CGI" "Digest::SHA")
MISSING_MODULES=()

for module in "${MODULES[@]}"; do
    if perl -M"$module" -e 1 2>/dev/null; then
        echo -e "${GREEN}[OK]${NC} $module"
    else
        echo -e "${RED}[MISSING]${NC} $module"
        MISSING_MODULES+=("$module")
    fi
done

if [ ${#MISSING_MODULES[@]} -gt 0 ]; then
    echo ""
    echo -e "${YELLOW}Missing modules. Install with:${NC}"
    echo "sudo cpan ${MISSING_MODULES[*]}"
    echo ""
    echo "Or on Debian/Ubuntu:"
    echo "sudo apt-get install libdbi-perl libdbd-mysql-perl libjson-perl libwww-perl"
    echo ""
    read -p "Continue anyway? (y/n) " -n 1 -r
    echo
    if [[ ! $REPLY =~ ^[Yy]$ ]]; then
        exit 1
    fi
fi

echo ""
echo "Step 2: Database Setup"
echo "----------------------------------------------"

# Check for password file
if [ -f "/usr/lib/cgi-bin/sql.txt" ]; then
    echo -e "${GREEN}[OK]${NC} MySQL password file found"
else
    echo -e "${YELLOW}[WARN]${NC} MySQL password file not found at /usr/lib/cgi-bin/sql.txt"
    echo "Please create this file with your MySQL root password."
    read -p "Enter MySQL password (will be saved): " mysql_pass
    sudo mkdir -p /usr/lib/cgi-bin
    echo "$mysql_pass" | sudo tee /usr/lib/cgi-bin/sql.txt > /dev/null
    sudo chmod 600 /usr/lib/cgi-bin/sql.txt
    echo -e "${GREEN}[OK]${NC} Password file created"
fi

# Read the password
MYSQL_PASS=$(cat /usr/lib/cgi-bin/sql.txt 2>/dev/null | tr -d '[:space:]')

echo ""
echo "Creating database and tables..."
mysql -u root -p"$MYSQL_PASS" < "$SCRIPT_DIR/sql/schema.sql"
echo -e "${GREEN}[OK]${NC} Database 'ergo_mm' created with all tables"

echo ""
echo "Step 3: Setting up CGI scripts"
echo "----------------------------------------------"

# Make scripts executable
chmod +x "$SCRIPT_DIR/cgi-bin/"*.pl
echo -e "${GREEN}[OK]${NC} Scripts made executable"

# Check if Apache CGI directory exists
CGI_DIR="/usr/lib/cgi-bin"
if [ -d "$CGI_DIR" ]; then
    echo "Copying scripts to $CGI_DIR..."
    sudo cp "$SCRIPT_DIR/cgi-bin/"*.pl "$CGI_DIR/"
    sudo chown www-data:www-data "$CGI_DIR/"*.pl 2>/dev/null || true
    sudo chmod 755 "$CGI_DIR/"*.pl
    echo -e "${GREEN}[OK]${NC} Scripts copied to CGI directory"
else
    echo -e "${YELLOW}[WARN]${NC} CGI directory not found at $CGI_DIR"
    echo "You'll need to manually copy the scripts to your web server's CGI directory."
fi

echo ""
echo "Step 4: Setting up cron job"
echo "----------------------------------------------"

# Create cron entry
CRON_ENTRY="*/5 * * * * /usr/bin/perl $CGI_DIR/monitor.pl >> /var/log/ergo_mm_monitor.log 2>&1"

echo "Suggested cron entry (runs every 5 minutes):"
echo "$CRON_ENTRY"
echo ""
read -p "Add to crontab? (y/n) " -n 1 -r
echo
if [[ $REPLY =~ ^[Yy]$ ]]; then
    (crontab -l 2>/dev/null | grep -v "monitor.pl"; echo "$CRON_ENTRY") | crontab -
    echo -e "${GREEN}[OK]${NC} Cron job added"
else
    echo "To add manually, run: crontab -e"
    echo "And add: $CRON_ENTRY"
fi

# Create log file
sudo touch /var/log/ergo_mm_monitor.log
sudo chmod 666 /var/log/ergo_mm_monitor.log

echo ""
echo "=============================================="
echo "Setup Complete!"
echo "=============================================="
echo ""
echo "Dashboard URL: http://your-server/cgi-bin/dashboard.pl"
echo "API URL: http://your-server/cgi-bin/api.pl"
echo "Password: ergo_IS_FOR_anyone"
echo ""
echo "Next steps:"
echo "1. Configure your Discord webhook in the dashboard settings"
echo "2. Adjust alert thresholds as needed"
echo "3. Run the monitor manually to test: perl $CGI_DIR/monitor.pl"
echo "4. Check the log: tail -f /var/log/ergo_mm_monitor.log"
echo ""
echo "API Endpoints:"
echo "  ?endpoint=overview     - Full dashboard data"
echo "  ?endpoint=prices       - Price history"
echo "  ?endpoint=depth        - Orderbook depth history"
echo "  ?endpoint=alerts       - Alert history"
echo "  ?endpoint=trades       - Trade summary"
echo "  ?endpoint=health       - System health (no auth needed)"
echo ""
