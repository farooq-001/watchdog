#!/bin/bash

# Variables
VENV_DIR="/opt/watchdog_env"
SCRIPT_PATH="/opt/file_monitor.py"
SERVICE_PATH="/etc/systemd/system/watchdog.service"
LOG_FILE="/var/log/watchdog.log"
INSTALL_FLAG="/var/log/.install-watchdog-pro.log"

# Prevent reinstall
if [ -f "$INSTALL_FLAG" ]; then
    echo "⛔ Watchdog is already installed."
    echo "ℹ️  Log File: $LOG_FILE"
    echo "ℹ️  Marker File: $INSTALL_FLAG"
    exit 0
fi

echo "[+] Detecting OS and installing dependencies..."

# OS Detection
if [ -f /etc/debian_version ]; then
    echo "✅ Detected Debian-based system (Ubuntu/Debian)"
    sudo apt update -y
    sudo apt install -y python3 python3-venv python3-pip
elif [ -f /etc/redhat-release ] || grep -qi 'fedora' /etc/os-release; then
    OS_NAME=$(grep "^NAME=" /etc/os-release | cut -d= -f2 | tr -d '"')
    echo "✅ Detected RHEL-based system: $OS_NAME"
    if command -v dnf &> /dev/null; then
        sudo dnf install -y python3 python3-pip
    else
        sudo yum install -y python3 python3-pip
    fi
else
    echo "❌ Unsupported OS. Only Ubuntu/Debian and RHEL-based systems are supported."
    exit 1
fi

echo "[+] Creating virtual environment at $VENV_DIR..."
python3 -m venv $VENV_DIR
source $VENV_DIR/bin/activate
pip install --upgrade pip
pip install watchdog

# Python monitoring script
echo "[+] Creating file monitor script at $SCRIPT_PATH..."
cat <<EOF > $SCRIPT_PATH
import os
import time
import logging
import gzip
import shutil
from watchdog.observers import Observer
from watchdog.events import FileSystemEventHandler
from datetime import datetime

LOG_FILE = "$LOG_FILE"
COMPRESS_INTERVAL = 3600  # 1 hour
LOG_RETENTION_DAYS = 7

ICONS = {
    'created': '🌱',
    'modified': '🛠️',
    'deleted': '🗑️',
    'moved': '🔁',
    'file': '📄',
    'dir': '📘',
    'increase': '📈',
    'decrease': '📉'
}

EXCLUDE_DIRS = ["/proc", "/sys", "/dev", "/run", "/tmp", "/var/cache", "/var/tmp", LOG_FILE]

logging.basicConfig(filename=LOG_FILE, level=logging.INFO, format="%(asctime)s - %(message)s")

class MonitorHandler(FileSystemEventHandler):
    def __init__(self):
        self.file_sizes = {}

    def format_size(self, size):
        for unit in ['B', 'KB', 'MB', 'GB', 'TB']:
            if size < 1024.0:
                return f"{size:.2f} {unit}"
            size /= 1024.0
        return f"{size:.2f} PB"

    def should_ignore(self, path):
        return any(path.startswith(ex) for ex in EXCLUDE_DIRS)

    def log(self, action, path, icon):
        if self.should_ignore(path): return
        ftype = ICONS['dir'] if os.path.isdir(path) else ICONS['file']
        logging.info(f"{icon} {action.upper()} {ftype} {path}")

    def on_created(self, event):
        self.log('created', event.src_path, ICONS['created'])
        if not event.is_directory and os.path.exists(event.src_path):
            self.file_sizes[event.src_path] = os.path.getsize(event.src_path)

    def on_deleted(self, event):
        self.log('deleted', event.src_path, ICONS['deleted'])
        self.file_sizes.pop(event.src_path, None)

    def on_moved(self, event):
        if self.should_ignore(event.src_path): return
        ftype = ICONS['dir'] if event.is_directory else ICONS['file']
        logging.info(f"{ICONS['moved']} MOVED {ftype} {event.src_path} ➡️ {event.dest_path}")
        if not event.is_directory:
            self.file_sizes[event.dest_path] = self.file_sizes.pop(event.src_path, 0)

    def on_modified(self, event):
        if event.is_directory or self.should_ignore(event.src_path): return
        try:
            new_size = os.path.getsize(event.src_path)
            old_size = self.file_sizes.get(event.src_path, new_size)
            if new_size != old_size:
                diff = new_size - old_size
                icon = ICONS['increase'] if diff > 0 else ICONS['decrease']
                logging.info(
                    f"{ICONS['modified']} MODIFIED {ICONS['file']} {event.src_path} {icon} {self.format_size(abs(diff))} "
                    f"(old: {self.format_size(old_size)}, new: {self.format_size(new_size)})"
                )
            else:
                logging.info(f"{ICONS['modified']} MODIFIED {ICONS['file']} {event.src_path}")
            self.file_sizes[event.src_path] = new_size
        except FileNotFoundError:
            pass

def compress_logs():
    if not os.path.exists(LOG_FILE): return
    ts = datetime.now().strftime("%Y%m%d_%H%M%S")
    comp_log = f"{LOG_FILE}_{ts}.gz"
    with open(LOG_FILE, "rb") as src, gzip.open(comp_log, "wb") as dst:
        shutil.copyfileobj(src, dst)
    open(LOG_FILE, 'w').close()
    logging.info(f"Compressed log: {comp_log}")

def delete_old_logs():
    now = time.time()
    for f in os.listdir("/var/log"):
        if f.startswith("watchdog.log") and f.endswith(".gz"):
            path = os.path.join("/var/log", f)
            if time.time() - os.path.getmtime(path) > LOG_RETENTION_DAYS * 86400:
                os.remove(path)
                logging.info(f"Deleted old log: {path}")

def get_paths():
    paths = ["/home", "/etc", "/usr", "/opt", "/root"]
    return [p for p in paths if os.path.exists(p)]

def main():
    observer = Observer()
    handler = MonitorHandler()
    for path in get_paths():
        observer.schedule(handler, path, recursive=True)
    observer.start()
    logging.info("🚀 Watchdog started monitoring.")
    try:
        while True:
            compress_logs()
            delete_old_logs()
            time.sleep(COMPRESS_INTERVAL)
    except KeyboardInterrupt:
        observer.stop()
    observer.join()

if __name__ == "__main__":
    main()
EOF

# systemd service
echo "[+] Creating systemd service..."
cat <<EOF | sudo tee $SERVICE_PATH > /dev/null
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
EOF

# Enable and start service
echo "[+] Enabling and starting watchdog..."
sudo systemctl daemon-reload
sudo systemctl enable watchdog.service
sudo systemctl start watchdog.service

# Create install flag
sudo touch "$INSTALL_FLAG"

echo "✅ Installation complete!"
echo "📁 Log file: $LOG_FILE"
echo "⚙️  Service: watchdog.service"
