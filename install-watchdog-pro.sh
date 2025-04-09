#!/bin/bash

# Variables
VENV_DIR="/opt/watchdog_env"
SCRIPT_PATH="/opt/file_monitor.py"
SERVICE_PATH="/etc/systemd/system/watchdog.service"
LOG_FILE="/var/log/watchdog.log"
INSTALL_FLAG="/var/log/.install-watchdog-pro.log"

# Prevent reinstall
if [ -f "$INSTALL_FLAG" ]; then
    echo "⛔ Watchdog is already installed. Please check the service or uninstall before reinstalling."
    echo "ℹ️  Log File: $LOG_FILE"
    echo "ℹ️  Installed marker: $INSTALL_FLAG"
    exit 0
fi

# Check for root privileges
if [ "$EUID" -ne 0 ]; then
    echo "❌ This script must be run as root. Please use sudo."
    exit 1
fi

echo "[+] Detecting OS and installing dependencies..."
if [ -f /etc/debian_version ]; then
    echo "✅ Detected Debian-based system (Ubuntu/Debian)"
    apt update -y
    apt install -y python3 python3-venv python3-pip
elif [ -f /etc/redhat-release ] || grep -qi 'fedora' /etc/os-release; then
    OS_NAME=$(grep "^NAME=" /etc/os-release | cut -d= -f2 | tr -d '"')
    echo "✅ Detected $OS_NAME"
    if command -v dnf &> /dev/null; then
        dnf install -y python3 python3-pip
    else
        yum install -y python3 python3-pip
    fi
else
    echo "❌ Unsupported OS."
    exit 1
fi

echo "[+] Setting up virtual environment..."
python3 -m venv "$VENV_DIR"
source "$VENV_DIR/bin/activate"
pip install --upgrade pip
pip install watchdog

echo "[+] Writing file monitor script..."
cat <<'EOL' > "$SCRIPT_PATH"
import os
import time
import logging
import shutil
import gzip
from watchdog.observers import Observer
from watchdog.events import FileSystemEventHandler
from datetime import datetime
import pwd
import grp

LOG_FILE = "/var/log/watchdog.log"
COMPRESS_INTERVAL = 3600
LOG_RETENTION_DAYS = 7

ICONS = {
    'created': '🌱',
    'modified': '🔧',
    'deleted': '🗑️',
    'moved': '🔄',
    'copy': '📋',
    'dir': '📘',
    'file': '📄',
    'symlink': '🔗',
    'hardlink': '🪝',
    'perms': '🔒',
    'owner': '👤'
}

EXCLUDE_DIRS = ["/proc", "/sys", "/dev", "/run", "/tmp", "/var/cache", "/var/tmp", LOG_FILE]

logging.basicConfig(filename=LOG_FILE, level=logging.INFO, format="%(asctime)s - %(message)s")

class FileMonitorHandler(FileSystemEventHandler):
    def __init__(self):
        self.file_sizes = {}
        self.inode_map = {}
        self.permissions = {}
        self.ownership = {}

    def format_size(self, size):
        for unit in ['B', 'KB', 'MB', 'GB']:
            if size < 1024:
                return f"{size:.2f} {unit}"
            size /= 1024
        return f"{size:.2f} TB"

    def get_file_info(self, path):
        try:
            stat = os.stat(path)
            perms = oct(stat.st_mode)[-3:]
            owner = pwd.getpwuid(stat.st_uid).pw_name
            group = grp.getgrgid(stat.st_gid).gr_name
            return perms, f"{owner}:{group}"
        except:
            return "???", "unknown:unknown"

    def should_ignore(self, path):
        return any(path.startswith(ex) for ex in EXCLUDE_DIRS)

    def log_event(self, action, path, icon):
        if self.should_ignore(path): return
        typ = ICONS['dir'] if os.path.isdir(path) else ICONS['file']
        logging.info(f"{icon} {action.upper()} {typ} {path}")

    def check_perm_owner_changes(self, path):
        if self.should_ignore(path) or not os.path.exists(path):
            return
        
        current_perms, current_owner = self.get_file_info(path)
        old_perms = self.permissions.get(path)
        old_owner = self.ownership.get(path)

        if old_perms and old_perms != current_perms:
            logging.info(f"{ICONS['perms']} PERMISSIONS CHANGED {ICONS['file']} {path}: "
                        f"{old_perms} ➡️ {current_perms} (owner: {current_owner})")

        if old_owner and old_owner != current_owner:
            logging.info(f"{ICONS['owner']} OWNERSHIP CHANGED {ICONS['file']} {path}: "
                        f"{old_owner} ➡️ {current_owner} (perms: {current_perms})")

        self.permissions[path] = current_perms
        self.ownership[path] = current_owner

    def on_created(self, event):
        path = event.src_path
        if self.should_ignore(path): return

        try:
            if os.path.islink(path):
                logging.info(f"{ICONS['symlink']} SYMLINK CREATED {path} -> {os.readlink(path)}")
            elif os.path.isfile(path):
                stat = os.lstat(path)
                inode = stat.st_ino
                perms, owner = self.get_file_info(path)
                self.permissions[path] = perms
                self.ownership[path] = owner

                if inode in self.inode_map:
                    source = self.inode_map[inode]
                    logging.info(f"{ICONS['copy']} COPY DETECTED {source} ➡️ {path}")
                else:
                    self.inode_map[inode] = path

                if stat.st_nlink > 1:
                    logging.info(f"{ICONS['hardlink']} HARD LINK DETECTED: {path} (inode: {inode}, links: {stat.st_nlink})")

                self.file_sizes[path] = stat.st_size
        except Exception as e:
            logging.error(f"Error on created event: {e}")

        self.log_event("created", path, ICONS['created'])

    def on_deleted(self, event):
        path = event.src_path
        self.log_event("deleted", path, ICONS['deleted'])
        self.file_sizes.pop(path, None)
        self.permissions.pop(path, None)
        self.ownership.pop(path, None)

    def on_moved(self, event):
        if self.should_ignore(event.src_path): return
        typ = ICONS['dir'] if event.is_directory else ICONS['file']
        logging.info(f"{ICONS['moved']} MOVED {typ} {event.src_path} ➡️ {event.dest_path}")
        self.file_sizes[event.dest_path] = self.file_sizes.pop(event.src_path, 0)
        self.permissions[event.dest_path] = self.permissions.pop(event.src_path, None)
        self.ownership[event.dest_path] = self.ownership.pop(event.src_path, None)
        self.check_perm_owner_changes(event.dest_path)

    def on_modified(self, event):
        path = event.src_path
        if event.is_directory or self.should_ignore(path): return
        try:
            new_size = os.path.getsize(path)
            old_size = self.file_sizes.get(path, new_size)
            self.check_perm_owner_changes(path)

            if new_size != old_size:
                delta = new_size - old_size
                change = "➕" if delta > 0 else "➖"
                perms, owner = self.get_file_info(path)
                logging.info(
                    f"{ICONS['modified']} MODIFIED {ICONS['file']} {path} {change} {self.format_size(abs(delta))} "
                    f"(old: {self.format_size(old_size)}, new: {self.format_size(new_size)}, "
                    f"perms: {perms}, owner: {owner})"
                )
            else:
                perms, owner = self.get_file_info(path)
                logging.info(f"{ICONS['modified']} MODIFIED {ICONS['file']} {path} "
                           f"(perms: {perms}, owner: {owner})")
            self.file_sizes[path] = new_size
        except Exception as e:
            logging.error(f"Error on modified event: {e}")

def get_paths():
    return [p for p in ["/home", "/etc", "/usr", "/opt", "/root"] if os.path.exists(p)]

def compress_log():
    if not os.path.exists(LOG_FILE): return
    ts = datetime.now().strftime("%Y%m%d_%H%M%S")
    dest = f"{LOG_FILE}_{ts}.gz"
    with open(LOG_FILE, "rb") as f_in, gzip.open(dest, "wb") as f_out:
        shutil.copyfileobj(f_in, f_out)
    open(LOG_FILE, 'w').close()
    logging.info(f"Compressed log: {dest}")

def delete_old_logs():
    now = time.time()
    for f in os.listdir("/var/log"):
        path = os.path.join("/var/log", f)
        if f.startswith("watchdog.log") and f.endswith(".gz") and os.path.isfile(path):
            if now - os.path.getmtime(path) > LOG_RETENTION_DAYS * 86400:
                os.remove(path)
                logging.info(f"Deleted old log: {path}")

def main():
    handler = FileMonitorHandler()
    obs = Observer()
    for p in get_paths():
        obs.schedule(handler, p, recursive=True)
    obs.start()
    logging.info("📢 Watchdog started.")
    try:
        while True:
            compress_log()
            delete_old_logs()
            time.sleep(COMPRESS_INTERVAL)
    except KeyboardInterrupt:
        obs.stop()
    obs.join()

if __name__ == "__main__":
    main()
EOL

echo "[+] Setting permissions for script..."
chmod 755 "$SCRIPT_PATH"

echo "[+] Creating systemd service..."
cat <<EOL > "$SERVICE_PATH"
[Unit]
Description=Watchdog File Monitor
After=network.target

[Service]
Type=simple
ExecStart=$VENV_DIR/bin/python $SCRIPT_PATH
WorkingDirectory=/opt
User=root
Group=root
Restart=always
Environment="PATH=$VENV_DIR/bin:/usr/bin:/bin"
Environment="PYTHONUNBUFFERED=1"

[Install]
WantedBy=multi-user.target
EOL

echo "[+] Setting permissions for service file..."
chmod 644 "$SERVICE_PATH"

echo "[+] Enabling and starting service..."
systemctl daemon-reload
systemctl enable watchdog.service
systemctl start watchdog.service

# Verify service status
sleep 2
if systemctl is-active watchdog.service > /dev/null; then
    echo "[✅] Watchdog service started successfully!"
else
    echo "[❌] Failed to start Watchdog service. Check logs: $LOG_FILE"
    exit 1
fi

touch "$INSTALL_FLAG"
echo "[✅] Watchdog installed successfully!"
echo "[📁] Log: $LOG_FILE"
echo "[ℹ️] To check status: systemctl status watchdog.service"
echo "[ℹ️] To view logs: tail -f $LOG_FILE"

echo ""
echo "==============================="
echo "🐾  Watch-dog is on duty to monitor the files & directories"
echo "==============================="
echo ""
echo "     / \\__"
echo "    (    @\\___"
echo "    /         O"
echo "  /   (_____ /"
echo " /_____/   U"
echo ""


