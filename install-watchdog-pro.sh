#!/bin/bash

# Variables
VENV_DIR="/opt/watchdog_env"
SCRIPT_PATH="/opt/file_monitor.py"
SERVICE_PATH="/etc/systemd/system/watchdog.service"
LOG_FILE="/var/log/watchdog.log"

echo "[+] Detecting OS and installing dependencies..."

# OS Detection and Package Installation
if [ -f /etc/debian_version ]; then
    echo "✅ Detected Debian-based system (Ubuntu/Debian)"
    sudo apt update -y
    sudo apt install -y python3 python3-venv python3-pip

elif [ -f /etc/redhat-release ] || grep -qi 'fedora' /etc/os-release; then
    OS_NAME=$(grep "^NAME=" /etc/os-release | cut -d= -f2 | tr -d '"')
    case "$OS_NAME" in
        *Rocky*)
            echo "✅ Detected Rocky Linux"
            ;;
        *CentOS*)
            echo "✅ Detected CentOS"
            ;;
        *Red\ Hat*)
            echo "✅ Detected Red Hat Enterprise Linux"
            ;;
        *Fedora*)
            echo "✅ Detected Fedora"
            ;;
        *)
            echo "⚠️  Detected RHEL-based system: $OS_NAME"
            ;;
    esac

    # Try DNF first, fallback to YUM if needed
    if command -v dnf &> /dev/null; then
        sudo dnf install -y python3 python3-pip
    else
        sudo yum install -y python3 python3-pip
    fi

else
    echo "❌ Unsupported OS. Only Ubuntu/Debian and RHEL-based systems (CentOS, Rocky, Fedora, RHEL) are supported."
    exit 1
fi

echo "[+] Creating virtual environment at $VENV_DIR..."
python3 -m venv $VENV_DIR

source $VENV_DIR/bin/activate
pip install --upgrade pip
pip install watchdog

echo "[+] Writing monitor script to $SCRIPT_PATH..."
cat <<EOL > $SCRIPT_PATH
import os
import time
import logging
import gzip
import shutil
from watchdog.observers import Observer
from watchdog.events import FileSystemEventHandler
from datetime import datetime

LOG_FILE = "$LOG_FILE"
COMPRESS_INTERVAL = 3600  # seconds
LOG_RETENTION_DAYS = 7

# Icons
ICONS = {
    'created': '🌱',
    'modified': '🔧',
    'deleted': '🗑️',
    'moved': '🔄',
    'dir': '📘',
    'file': '📄'
}

EXCLUDE_DIRS = [
    "/proc", "/sys", "/dev", "/run", "/tmp", "/var/cache", "/var/tmp", LOG_FILE
]

logging.basicConfig(filename=LOG_FILE, level=logging.INFO, format="%(asctime)s - %(message)s")

class FileMonitorHandler(FileSystemEventHandler):
    def __init__(self):
        self.file_sizes = {}

    def format_size(self, size):
        for unit in ['B', 'KB', 'MB', 'GB', 'TB']:
            if size < 1024:
                return f"{size:.2f} {unit}"
            size /= 1024
        return f"{size:.2f} PB"

    def should_ignore(self, path):
        return any(path.startswith(ex) for ex in EXCLUDE_DIRS)

    def log_event(self, event_type, path, icon):
        if self.should_ignore(path): return
        entry_type = ICONS['dir'] if os.path.isdir(path) else ICONS['file']
        logging.info(f"{icon} {event_type.upper()} {entry_type} {path}")

    def on_created(self, event):
        self.log_event('created', event.src_path, ICONS['created'])
        if not event.is_directory and os.path.exists(event.src_path):
            self.file_sizes[event.src_path] = os.path.getsize(event.src_path)

    def on_deleted(self, event):
        self.log_event('deleted', event.src_path, ICONS['deleted'])
        self.file_sizes.pop(event.src_path, None)

    def on_moved(self, event):
        if self.should_ignore(event.src_path): return
        entry_type = ICONS['dir'] if event.is_directory else ICONS['file']
        logging.info(f"{ICONS['moved']} MOVED {entry_type} {event.src_path} ➡️ {event.dest_path}")
        self.file_sizes[event.dest_path] = self.file_sizes.pop(event.src_path, 0)

    def on_modified(self, event):
        if event.is_directory or self.should_ignore(event.src_path): return
        new_size = os.path.getsize(event.src_path)
        old_size = self.file_sizes.get(event.src_path, new_size)

        if new_size != old_size:
            delta = new_size - old_size
            change_type = "➕" if delta > 0 else "➖"
            logging.info(
                f"{ICONS['modified']} MODIFIED {ICONS['file']} {event.src_path} {change_type} {self.format_size(abs(delta))} "
                f"(old: {self.format_size(old_size)}, new: {self.format_size(new_size)})"
            )
        else:
            logging.info(f"{ICONS['modified']} MODIFIED {ICONS['file']} {event.src_path}")

        self.file_sizes[event.src_path] = new_size

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
            compress_log()
            delete_old_logs()
            time.sleep(COMPRESS_INTERVAL)
    except KeyboardInterrupt:
        observer.stop()
    observer.join()

if __name__ == "__main__":
    main()
EOL

echo "[+] Creating systemd service at $SERVICE_PATH..."
cat <<EOL | sudo tee $SERVICE_PATH > /dev/null
[Unit]
Description=Watchdog File Integrity Monitor
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

echo "[+] Enabling and starting watchdog service..."
sudo systemctl daemon-reload
sudo systemctl enable watchdog.service
sudo systemctl start watchdog.service

echo "[✅] Watchdog installation and setup complete!"
echo "[📂] Log file location: $LOG_FILE"
