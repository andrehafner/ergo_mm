# Server Migration Guide - ERGO Market Maker

Complete guide for migrating to a new server with nginx for mm.ergoplatform.com

## Quick Start (Automated)

If you want to run everything automatically:

```bash
# On new server
git clone <your-repo> /opt/ergo_mm
cd /opt/ergo_mm
sudo bash deploy/install.sh

# Migrate data from old server
sudo bash deploy/migrate-data.sh migrate user@old-server.com
```

---

## Manual Step-by-Step Guide

### Step 1: Install System Packages

```bash
# Update system
sudo apt-get update && sudo apt-get upgrade -y

# Install nginx and fcgiwrap (for Perl CGI support)
sudo apt-get install -y nginx fcgiwrap

# Install MySQL
sudo apt-get install -y mysql-server mysql-client

# Install Perl and required modules
sudo apt-get install -y \
    perl \
    libdbi-perl \
    libdbd-mysql-perl \
    libjson-perl \
    libwww-perl \
    libdigest-sha-perl \
    libcgi-pm-perl \
    libtime-hires-perl

# Install certbot for SSL
sudo apt-get install -y certbot python3-certbot-nginx
```

### Step 2: Start and Enable Services

```bash
sudo systemctl start nginx
sudo systemctl enable nginx

sudo systemctl start fcgiwrap
sudo systemctl enable fcgiwrap

sudo systemctl start mysql
sudo systemctl enable mysql
```

### Step 3: Create Directory Structure

```bash
# Create application directory
sudo mkdir -p /var/www/ergo_mm/cgi-bin
sudo mkdir -p /var/log/ergo_mm

# Set ownership
sudo chown -R www-data:www-data /var/www/ergo_mm
```

### Step 4: Clone/Copy Application Files

```bash
# Option A: Clone from git
cd /opt
sudo git clone <your-repo-url> ergo_mm
sudo cp /opt/ergo_mm/*.pl /var/www/ergo_mm/cgi-bin/

# Option B: Copy from old server
scp user@old-server:/path/to/*.pl /var/www/ergo_mm/cgi-bin/

# Set permissions
sudo chmod 755 /var/www/ergo_mm/cgi-bin/*.pl
sudo chown www-data:www-data /var/www/ergo_mm/cgi-bin/*.pl
```

### Step 5: Configure MySQL

```bash
# Secure MySQL installation
sudo mysql_secure_installation

# Log into MySQL
sudo mysql -u root -p

# Create database (if fresh install)
CREATE DATABASE ergo_mm CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci;

# Enable event scheduler for automatic cleanup
SET GLOBAL event_scheduler = ON;

# Exit MySQL
exit
```

**Import schema (fresh install):**
```bash
mysql -u root -p ergo_mm < /opt/ergo_mm/sql/schema.sql
mysql -u root -p ergo_mm < /opt/ergo_mm/sql/add_user_tables.sql
```

**OR migrate data from old server (see Step 8).**

### Step 6: Create Configuration Files

```bash
# Create MySQL password file
echo "YOUR_MYSQL_PASSWORD" | sudo tee /var/www/ergo_mm/cgi-bin/sql.txt
sudo chmod 600 /var/www/ergo_mm/cgi-bin/sql.txt
sudo chown www-data:www-data /var/www/ergo_mm/cgi-bin/sql.txt

# Also create in legacy location (scripts check both)
sudo mkdir -p /usr/lib/cgi-bin
echo "YOUR_MYSQL_PASSWORD" | sudo tee /usr/lib/cgi-bin/sql.txt
sudo chmod 600 /usr/lib/cgi-bin/sql.txt
```

**Optional: Exchange API keys for balance tracking:**
```bash
sudo tee /var/www/ergo_mm/cgi-bin/api_keys.conf << 'EOF'
MEXC_ACCESS_KEY=your_key_here
MEXC_SECRET_KEY=your_secret_here
KUCOIN_KEY=your_key_here
KUCOIN_SECRET=your_secret_here
KUCOIN_PASSPHRASE=your_passphrase_here
EOF

sudo chmod 600 /var/www/ergo_mm/cgi-bin/api_keys.conf
sudo chown www-data:www-data /var/www/ergo_mm/cgi-bin/api_keys.conf
```

### Step 7: Configure Nginx

Create the site configuration:

```bash
sudo tee /etc/nginx/sites-available/mm.ergoplatform.com << 'EOF'
server {
    listen 80;
    server_name mm.ergoplatform.com;

    root /var/www/ergo_mm;
    index index.html;

    # CGI scripts
    location /cgi-bin/ {
        alias /var/www/ergo_mm/cgi-bin/;
        fastcgi_pass unix:/var/run/fcgiwrap.socket;
        fastcgi_param SCRIPT_FILENAME $request_filename;
        include fastcgi_params;
        fastcgi_param DOCUMENT_ROOT /var/www/ergo_mm;
        fastcgi_param SERVER_NAME $server_name;
        fastcgi_param REMOTE_ADDR $remote_addr;
        fastcgi_param REQUEST_METHOD $request_method;
        fastcgi_param QUERY_STRING $query_string;
        fastcgi_param CONTENT_TYPE $content_type;
        fastcgi_param CONTENT_LENGTH $content_length;
    }

    # Redirect root to dashboard
    location = / {
        return 302 /cgi-bin/dashboard.pl;
    }

    access_log /var/log/nginx/mm.ergoplatform.com.access.log;
    error_log /var/log/nginx/mm.ergoplatform.com.error.log;
}
EOF
```

Enable the site:

```bash
# Enable site
sudo ln -sf /etc/nginx/sites-available/mm.ergoplatform.com /etc/nginx/sites-enabled/

# Remove default site
sudo rm -f /etc/nginx/sites-enabled/default

# Test configuration
sudo nginx -t

# Reload nginx
sudo systemctl reload nginx
```

### Step 8: Migrate Data from Old Server

**Option A: Full automated migration (from new server):**
```bash
sudo bash /opt/ergo_mm/deploy/migrate-data.sh migrate user@old-server.com
```

**Option B: Manual migration:**

On OLD server:
```bash
# Export database
mysqldump -u root -p \
    --single-transaction \
    --routines \
    --triggers \
    --events \
    ergo_mm | gzip > ergo_mm_backup.sql.gz

# Transfer to new server
scp ergo_mm_backup.sql.gz user@new-server:/tmp/
```

On NEW server:
```bash
# Import database
gunzip -c /tmp/ergo_mm_backup.sql.gz | mysql -u root -p ergo_mm
```

### Step 9: Setup SSL Certificate

```bash
# Get SSL certificate from Let's Encrypt
sudo certbot --nginx -d mm.ergoplatform.com

# Certbot will:
# - Obtain certificate
# - Modify nginx config to use HTTPS
# - Setup auto-renewal
```

### Step 10: Setup Monitoring Cron Job

```bash
# Edit crontab
sudo crontab -e

# Add this line (runs every 5 minutes):
*/5 * * * * /usr/bin/perl /var/www/ergo_mm/cgi-bin/monitor.pl >> /var/log/ergo_mm/monitor.log 2>&1
```

Create log file:
```bash
sudo touch /var/log/ergo_mm/monitor.log
sudo chmod 666 /var/log/ergo_mm/monitor.log
```

---

## Verification

### Test Dashboard
```bash
curl -I http://mm.ergoplatform.com/cgi-bin/dashboard.pl
# Should return 200 OK
```

### Test API
```bash
curl http://mm.ergoplatform.com/cgi-bin/api.pl?endpoint=health
# Should return JSON with status
```

### Check Database
```bash
mysql -u root -p ergo_mm -e "SELECT * FROM v_latest_prices;"
```

### Monitor Logs
```bash
# Application log
tail -f /var/log/ergo_mm/monitor.log

# Nginx error log
tail -f /var/log/nginx/mm.ergoplatform.com.error.log
```

---

## Troubleshooting

### 502 Bad Gateway
```bash
# Check if fcgiwrap is running
sudo systemctl status fcgiwrap

# Check socket permissions
ls -la /var/run/fcgiwrap.socket

# Restart fcgiwrap
sudo systemctl restart fcgiwrap
```

### Permission Denied
```bash
# Fix CGI script permissions
sudo chmod 755 /var/www/ergo_mm/cgi-bin/*.pl
sudo chown www-data:www-data /var/www/ergo_mm/cgi-bin/*
```

### Database Connection Failed
```bash
# Check MySQL is running
sudo systemctl status mysql

# Verify password file
sudo cat /var/www/ergo_mm/cgi-bin/sql.txt

# Test connection manually
mysql -u root -p"$(cat /var/www/ergo_mm/cgi-bin/sql.txt)" ergo_mm -e "SELECT 1;"
```

### Perl Module Missing
```bash
# Check which module is missing from error log
tail /var/log/nginx/mm.ergoplatform.com.error.log

# Install missing module (example)
sudo apt-get install libsomething-perl
# or
sudo cpan Install::Module::Name
```

---

## Security Checklist

- [ ] Change default dashboard password in `dashboard.pl`, `api.pl`, `monitor.pl`
- [ ] Enable HTTPS with certbot
- [ ] Restrict MySQL to localhost only
- [ ] Secure `sql.txt` and `api_keys.conf` (chmod 600)
- [ ] Setup firewall (ufw) to only allow ports 80, 443, 22
- [ ] Never commit secrets to git

---

## File Locations Summary

| File | Location |
|------|----------|
| Dashboard | `/var/www/ergo_mm/cgi-bin/dashboard.pl` |
| API | `/var/www/ergo_mm/cgi-bin/api.pl` |
| Monitor | `/var/www/ergo_mm/cgi-bin/monitor.pl` |
| MySQL password | `/var/www/ergo_mm/cgi-bin/sql.txt` |
| API keys | `/var/www/ergo_mm/cgi-bin/api_keys.conf` |
| Nginx config | `/etc/nginx/sites-available/mm.ergoplatform.com` |
| App logs | `/var/log/ergo_mm/monitor.log` |
| Nginx logs | `/var/log/nginx/mm.ergoplatform.com.*.log` |

---

## URLs After Migration

| URL | Purpose |
|-----|---------|
| `https://mm.ergoplatform.com/` | Redirects to dashboard |
| `https://mm.ergoplatform.com/cgi-bin/dashboard.pl` | Main dashboard |
| `https://mm.ergoplatform.com/cgi-bin/api.pl?endpoint=health` | Health check |
| `https://mm.ergoplatform.com/cgi-bin/api.pl?endpoint=overview&api_key=PASSWORD` | Full API |
