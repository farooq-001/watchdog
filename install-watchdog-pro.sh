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

echo "[+] Detecting OS and installing dependencies..."
if [ -f /etc/debian_version ]; then
    echo "✅ Detected Debian-based system (Ubuntu/Debian)"
    sudo apt update -y
    sudo apt install -y python3 python3-venv python3-pip
elif [ -f /etc/redhat-release ] || grep -qi 'fedora' /etc/os-release; then
    OS_NAME=$(grep "^NAME=" /etc/os-release | cut -d= -f2 | tr -d '"')
    echo "✅ Detected $OS_NAME"
    if command -v dnf &> /dev/null; then
        sudo dnf install -y python3 python3-pip
    else
        sudo yum install -y python3 python3-pip
    fi
else
    echo "❌ Unsupported OS."
    exit 1
fi

echo "[+] Setting up virtual environment..."
python3 -m venv $VENV_DIR
source $VENV_DIR/bin/activate
pip install --upgrade pip
pip install watchdog

echo "[+] Writing file monitor script..."
cat <<EOL > $SCRIPT_PATH
import os
import time
import logging
import gzip
import shutil
from datetime import datetime
from watchdog.observers import Observer
from watchdog.events import FileSystemEventHandler

LOG_FILE = "$LOG_FILE"
COMPRESS_INTERVAL = 3600
LOG_RETENTION_DAYS = 7

ICONS = {
    'created': '🌱',
    'modified': '🔧',
    'deleted': '🗑️',
    'moved': '🔄',
    'dir': '📘',
    'file': '📄',
    'copied': '📥'
}

EXCLUDE_DIRS = [
    "/proc", "/sys", "/dev", "/run", "/tmp", "/var/cache", "/var/tmp", LOG_FILE
]

logging.basicConfig(filename=LOG_FILE, level=logging.INFO, format="%(asctime)s - %(message)s")

class FileMonitorHandler(FileSystemEventHandler):
    def __init__(self):
        self.file_sizes = {}
        self.recent_creations = {}

    def format_size(self, size):
        for unit in ['B','KB','MB','GB','TB']:
            if size < 1024:
                return f"{size:.2f} {unit}"
            size /= 1024
        return f"{size:.2f} PB"

    def should_ignore(self, path):
        return any(path.startswith(ex) for ex in EXCLUDE_DIRS)

    def log_event(self, action, path, icon):
        if self.should_ignore(path): return
        kind = ICONS['dir'] if os.path.isdir(path) else ICONS['file']
        logging.info(f"{icon} {action.upper()} {kind} {path}")

    def on_created(self, event):
        path = event.src_path
        if self.should_ignore(path): return
        self.log_event('created', path, ICONS['created'])
        if not event.is_directory and os.path.exists(path):
            size = os.path.getsize(path)
            self.file_sizes[path] = size
            self.recent_creations[path] = (time.time(), size)

    def on_deleted(self, event):
        path = event.src_path
        self.log_event('deleted', path, ICONS['deleted'])
        self.file_sizes.pop(path, None)
        self.recent_creations.pop(path, None)

    def on_moved(self, event):
        if self.should_ignore(event.src_path): return
        kind = ICONS['dir'] if event.is_directory else ICONS['file']
        logging.info(f"{ICONS['moved']} MOVED {kind} {event.src_path} ➡️ {event.dest_path}")
        if not event.is_directory:
            self.file_sizes[event.dest_path] = self.file_sizes.pop(event.src_path, 0)

    def on_modified(self, event):
        path = event.src_path
        if event.is_directory or self.should_ignore(path): return
        if not os.path.exists(path): return
        new_size = os.path.getsize(path)
        old_size = self.file_sizes.get(path, new_size)
        delta = new_size - old_size

        if new_size != old_size:
            change = "➕" if delta > 0 else "➖"
            logging.info(f"{ICONS['modified']} MODIFIED {ICONS['file']} {path} {change} {self.format_size(abs(delta))} (old: {self.format_size(old_size)}, new: {self.format_size(new_size)})")
        else:
            logging.info(f"{ICONS['modified']} MODIFIED {ICONS['file']} {path}")

        self.file_sizes[path] = new_size

    def detect_possible_copy(self):
        now = time.time()
        threshold = 10  # seconds
        for path, (ctime, size) in list(self.recent_creations.items()):
            if now - ctime < threshold:
                for other, (o_ctime, o_size) in self.recent_creations.items():
                    if path != other and abs(size - o_size) < 10:
                        logging.info(f"{ICONS['copied']} POSSIBLE COPY 📄 {other} ➡️ {path}")

def get_monitor_paths():
    paths = ["/home", "/etc", "/usr", "/opt", "/root"]
    return [p for p in paths if os.path.exists(p)]

def compress_log():
    if not os.path.exists(LOG_FILE): return
    timestamp = datetime.now().strftime("%Y%m%d_%H%M%S")
    compressed = f"{LOG_FILE}_{timestamp}.gz"
    with open(LOG_FILE, "rb") as f_in, gzip.open(compressed, "wb") as f_out:
        shutil.copyfileobj(f_in, f_out)
    open(LOG_FILE, 'w').close()
    logging.info(f"Compressed log saved: {compressed}")

def delete_old_logs():
    now = time.time()
    for fname in os.listdir("/var/log"):
        if fname.startswith("watchdog.log") and fname.endswith(".gz"):
            fpath = os.path.join("/var/log", fname)
            if os.path.isfile(fpath) and now - os.path.getmtime(fpath) > LOG_RETENTION_DAYS * 86400:
                os.remove(fpath)
                logging.info(f"Deleted old log: {fpath}")

def main():
    handler = FileMonitorHandler()
    observer = Observer()
    for path in get_monitor_paths():
        observer.schedule(handler, path, recursive=True)
    observer.start()
    logging.info("📢 Watchdog started.")
    try:
        while True:
            handler.detect_possible_copy()
            compress_log()
            delete_old_logs()
            time.sleep(COMPRESS_INTERVAL)
    except KeyboardInterrupt:
        observer.stop()
    observer.join()

if __name__ == "__main__":
    main()
EOL

echo "[+] Creating systemd service..."
cat <<EOL | sudo tee $SERVICE_PATH > /dev/null
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

echo "[+] Enabling and starting service..."
sudo systemctl daemon-reload
sudo systemctl enable watchdog.service
sudo systemctl start watchdog.service

touch "$INSTALL_FLAG"
echo "[✅] Watchdog installed!"
echo "[📁] Log: $LOG_FILE"
